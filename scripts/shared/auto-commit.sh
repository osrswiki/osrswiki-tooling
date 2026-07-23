#!/bin/bash
# Auto-commit script for Claude Code hooks - fast descriptive messages

# Only commit if there are actual changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    # Stage all changes
    git add -A
    
    # Get primary file for message generation (first file, most important)
    PRIMARY_FILE=$(git diff --cached --name-only | head -1)
    FILE_COUNT=$(git diff --cached --name-only | wc -l)
    
    # Fast categorization based on file patterns (no complex analysis)
    generate_message() {
        local file="$1"
        local count="$2"
        
        # Quick pattern matching for common cases
        case "$file" in
            *.sh) 
                echo "fix(scripts): update $(basename "$file")"
                ;;
            *.md)
                echo "docs: update $(basename "$file")"
                ;;
            .claude/*)
                echo "config: update Claude settings"
                ;;
            scripts/*)
                echo "fix(tooling): update $(basename "$file")"
                ;;
            *.kt|*.java)
                echo "feat: update $(basename "$file")"
                ;;
            *.json|*.gradle|*.kts)
                echo "config: update $(basename "$file")"
                ;;
            *)
                echo "update: modify $(basename "$file")"
                ;;
        esac
        
        # Add count suffix for multiple files
        if [ "$count" -gt 1 ]; then
            echo " (+$((count-1)) more)"
        fi
    }
    
    MESSAGE=$(generate_message "$PRIMARY_FILE" "$FILE_COUNT")
    
    git commit -m "$MESSAGE"
    
    echo "✅ Auto-committed: $MESSAGE"
else
    echo "📝 No changes to commit"
fi