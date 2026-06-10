#!/bin/bash

################################################################################
# Dependabot Auto-Merge Workflow Setup Script
# 
# This script sets up Dependabot auto-merge workflows across all your
# repositories with comprehensive error checking and logging.
#
# Usage: ./setup-dependabot-automerge.sh [OPTIONS]
# Options:
#   --dry-run              Show what would be done without making changes
#   --limit N              Limit to first N repositories
#   --skip-private         Skip private repositories
#   --skip-forks           Skip forked repositories
#   --log-file FILE        Specify custom log file path
#   --delay MIN-MAX        Set jitter delay range in seconds (default: 1-3)
#   --help                 Show this help message
################################################################################

set -o pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../.workflow-logs"
LOG_FILE="${LOG_DIR}/dependabot-setup-$(date +%Y%m%d_%H%M%S).log"
WORKFLOW_FILE="dependabot-auto-merge.yml"
DRY_RUN=false
REPO_LIMIT=""
SKIP_PRIVATE=false
SKIP_FORKS=false
USERNAME="meatflavourdev"
DELAY_MIN=1
DELAY_MAX=3
MAX_RETRIES=3
RETRY_BACKOFF_FACTOR=2
QUERY_PARAMS=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
TOTAL_REPOS=0
SUCCESSFUL=0
FAILED=0
SKIPPED=0
ALREADY_EXISTS=0
RATE_LIMITED=0

################################################################################
# Utility Functions
################################################################################

log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
    
    case $level in
        ERROR)
            echo -e "${RED}✗ ${message}${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}✓ ${message}${NC}"
            ;;
        WARNING)
            echo -e "${YELLOW}⚠ ${message}${NC}"
            ;;
        INFO)
            echo -e "${BLUE}ℹ ${message}${NC}"
            ;;
        RATE_LIMITED)
            echo -e "${CYAN}⏱ ${message}${NC}"
            ;;
        DEBUG)
            if [[ "${DEBUG}" == "true" ]]; then
                echo -e "${NC}  ${message}${NC}"
            fi
            ;;
    esac
}

show_help() {
    head -n 20 "$0" | tail -n +2 | sed 's/^# //'
}

check_dependencies() {
    log INFO "Checking dependencies..."
    
    if ! command -v gh &> /dev/null; then
        log ERROR "GitHub CLI (gh) is not installed. Please install it from https://cli.github.com/"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log WARNING "jq is not installed. Some features may be limited."
    fi
    
    # Test GitHub CLI authentication
    if ! gh auth status > /dev/null 2>&1; then
        log ERROR "Not authenticated with GitHub CLI. Run 'gh auth login' first."
        exit 1
    fi
    
    log SUCCESS "All dependencies satisfied"
}

setup_logging() {
    mkdir -p "$LOG_DIR"
    
    # Clear old log files (keep last 30 days)
    find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true
    
    log INFO "======================================"
    log INFO "Dependabot Auto-Merge Setup"
    log INFO "======================================"
    log INFO "Log file: $LOG_FILE"
    log INFO "Dry Run: $DRY_RUN"
    log INFO "Skip Private: $SKIP_PRIVATE"
    log INFO "Skip Forks: $SKIP_FORKS"
    log INFO "Jitter Delay: ${DELAY_MIN}-${DELAY_MAX} seconds"
    log INFO "Max Retries: $MAX_RETRIES"
    log INFO "Merge Strategy: squash (linear history)"
    [[ -n "$REPO_LIMIT" ]] && log INFO "Repo Limit: $REPO_LIMIT"
}

# Generate random jitter delay
random_delay() {
    local delay=$((RANDOM % ($DELAY_MAX - $DELAY_MIN + 1) + $DELAY_MIN))
    echo $delay
}

# Apply jitter delay before API call
apply_jitter_delay() {
    local delay=$(random_delay)
    log DEBUG "Applying jitter delay: ${delay}s"
    sleep "$delay"
}

# Check GitHub API rate limit status
check_rate_limit() {
    local rate_info=$(gh api rate_limit --jq '.rate.remaining,.rate.limit,.rate.reset' 2>/dev/null)
    
    if [[ -n "$rate_info" ]]; then
        local remaining=$(echo "$rate_info" | sed -n '1p')
        local limit=$(echo "$rate_info" | sed -n '2p')
        local reset=$(echo "$rate_info" | sed -n '3p')
        local reset_time=$(date -d "@$reset" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        
        log DEBUG "Rate limit: $remaining/$limit (resets at $reset_time)"
        
        # Warn if getting close to limit
        if [[ $remaining -lt 100 ]]; then
            log WARNING "Approaching rate limit: $remaining requests remaining"
        fi
        
        # Return 0 if we have requests left, 1 if rate limited
        [[ $remaining -gt 0 ]] && return 0 || return 1
    fi
    return 0
}

# Wait for rate limit reset with backoff
handle_rate_limit() {
    local retry_count=$1
    local backoff=$((RETRY_BACKOFF_FACTOR ** (retry_count - 1)))
    local wait_time=$((backoff * 5))
    
    log RATE_LIMITED "Rate limited! Waiting ${wait_time}s before retry (attempt $retry_count/$MAX_RETRIES)"
    ((RATE_LIMITED++))
    
    sleep "$wait_time"
}

create_workflow_content() {
    cat << 'WORKFLOW_EOF'
name: Dependabot auto-merge

on: pull_request

permissions:
  contents: write
  pull-requests: write

jobs:
  dependabot:
    runs-on: ubuntu-latest
    if: github.event.pull_request.user.login == 'dependabot[bot]'
    steps:
      - name: Dependabot metadata
        id: metadata
        uses: dependabot/fetch-metadata@v2
        with:
          github-token: "${{ secrets.GITHUB_TOKEN }}"
      
      - name: Enable auto-merge for Dependabot PRs
        run: gh pr merge --auto --squash "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
WORKFLOW_EOF
}

check_workflow_exists() {
    local repo=$1
    
    if gh api "repos/${repo}/contents/.github/workflows/${WORKFLOW_FILE}" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

setup_workflow() {
    local repo=$1
    local workflow_content=$(create_workflow_content)
    local retry_count=0
    
    log DEBUG "Setting up workflow for $repo"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY-RUN] Would create workflow in $repo"
        apply_jitter_delay
        return 0
    fi
    
    # Retry loop with exponential backoff
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        ((retry_count++))
        
        if ! check_rate_limit; then
            if [[ $retry_count -lt $MAX_RETRIES ]]; then
                handle_rate_limit "$retry_count"
                continue
            else
                log ERROR "Rate limited and max retries exceeded for $repo"
                ((FAILED++))
                return 1
            fi
        fi
        
        apply_jitter_delay
        
        # FIXED: OS-agnostic base64 encoding (macOS/Linux compatible)
        if gh api \
            --method PUT \
            "repos/${repo}/contents/.github/workflows/${WORKFLOW_FILE}" \
            -f message="chore: add dependabot auto-merge workflow" \
            -f content="$(echo -n "$workflow_content" | base64 | tr -d '\n')" \
            > /dev/null 2>&1; then
            
            log SUCCESS "Workflow created in $repo"
            ((SUCCESSFUL++))
            return 0
        else
            apply_jitter_delay
            if check_workflow_exists "$repo"; then
                log WARNING "Workflow already exists in $repo"
                ((ALREADY_EXISTS++))
                return 0
            else
                if [[ $retry_count -lt $MAX_RETRIES ]]; then
                    log WARNING "Failed to create workflow in $repo (Branch protection active?). Retrying..."
                    continue
                else
                    log ERROR "Failed to create workflow in $repo after $MAX_RETRIES attempts"
                    ((FAILED++))
                    return 1
                fi
            fi
        fi
    done
}

process_repositories() {
    log INFO "Fetching repositories..."
    
    apply_jitter_delay
    
    # Preserve query params globally so verify_setup can use them later
    QUERY_PARAMS="--limit ${REPO_LIMIT:-10000}"
    [[ "$SKIP_PRIVATE" == "true" ]] && QUERY_PARAMS="$QUERY_PARAMS --private=false"
    [[ "$SKIP_FORKS" == "true" ]] && QUERY_PARAMS="$QUERY_PARAMS --fork=false"
    
    # shellcheck disable=SC2086
    local repos=$(gh repo list "$USERNAME" $QUERY_PARAMS --json nameWithOwner -q '.[].nameWithOwner')
    
    if [[ -z "$repos" ]]; then
        log ERROR "No repositories found"
        return 1
    fi
    
    local repo_count=$(echo "$repos" | wc -l)
    TOTAL_REPOS=$repo_count
    log INFO "Found $repo_count repositories to process"
    
    local current=0
    while IFS= read -r repo; do
        ((current++))
        log INFO "[$current/$repo_count] Processing $repo..."
        
        apply_jitter_delay
        
        # FIXED: Skip archived repositories instead of checking for issues
        local is_archived=$(gh api "repos/${repo}" --jq '.archived' 2>/dev/null)
        if [[ "$is_archived" == "true" ]]; then
            log WARNING "Skipping $repo (Repository is archived)"
            ((SKIPPED++))
            continue
        fi
        
        setup_workflow "$repo"
    done <<< "$repos"
}

print_summary() {
    echo ""
    log INFO "======================================"
    log INFO "Setup Summary"
    log INFO "======================================"
    log INFO "Total Repositories: $TOTAL_REPOS"
    log SUCCESS "Successful: $SUCCESSFUL"
    log WARNING "Already Exists: $ALREADY_EXISTS"
    log ERROR "Failed: $FAILED"
    log WARNING "Skipped (archived): $SKIPPED"
    log RATE_LIMITED "Rate Limited (retried): $RATE_LIMITED"
    log INFO "======================================"
    log INFO "Log file saved to: $LOG_FILE"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log WARNING "DRY-RUN MODE: No actual changes were made"
    fi
}

verify_setup() {
    log INFO "Verifying workflow setup..."
    
    apply_jitter_delay
    
    local verified=0
    # FIXED: Re-use the exact parameters used during processing
    # shellcheck disable=SC2086
    local repos=$(gh repo list "$USERNAME" $QUERY_PARAMS --json nameWithOwner -q '.[].nameWithOwner')
    
    while IFS= read -r repo; do
        apply_jitter_delay
        if check_workflow_exists "$repo"; then
            ((verified++))
        fi
    done <<< "$repos"
    
    log SUCCESS "Verified $verified repositories with workflow installed"
    return 0
}

################################################################################
# Main Script
################################################################################

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --limit)
                REPO_LIMIT="$2"
                shift 2
                ;;
            --skip-private)
                SKIP_PRIVATE=true
                shift
                ;;
            --skip-forks)
                SKIP_FORKS=true
                shift
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            --delay)
                IFS='-' read -r DELAY_MIN DELAY_MAX <<< "$2"
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    setup_logging
    check_dependencies
    process_repositories
    verify_setup
    print_summary
    
    # Exit with error if there were failures
    if [[ $FAILED -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

main "$@"
