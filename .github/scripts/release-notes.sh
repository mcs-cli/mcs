#!/usr/bin/env bash
# Usage:
#   release-notes.sh check                    < PR body   → validate the "Release note" section
#   release-notes.sh build <tag> [<prev-tag>]             → release notes markdown on stdout
set -euo pipefail

# Written for bash 3.2 (the macOS default) so it can be previewed locally.

TAB=$'\t'

extract_section() {
    perl -0777 -ne '
        s/\r//g;
        s/<!--.*?-->//gs;
        if (/^##[ \t]+Release note[ \t]*\n(.*?)(?=^##[ \t]|\z)/msi) { print $1; exit 0 }
        exit 1;
    '
}

# Prints "NONE", or one "<CATEGORY>\t<text>" line per entry; errors go to stderr.
parse_note() {
    local section
    section=$(extract_section) || {
        echo "missing a '## Release note' section" >&2
        return 1
    }

    local errors="" logical="" line trimmed in_entry=0
    # Join wrapped lines onto the bullet they continue, as GitHub renders them, so each
    # logical line is one entry. A blank line ends the entry.
    while IFS= read -r line; do
        read -r trimmed <<<"$line"
        if [[ -z $trimmed ]]; then
            in_entry=0
            logical+=$'\n'
        elif [[ $trimmed =~ ^[-*]([[:space:]]|$) ]]; then
            if [[ $line =~ ^[[:space:]] ]]; then
                errors+="nested bullets are not supported — make it its own entry: $trimmed"$'\n'
                continue
            fi
            logical+="$trimmed"$'\n'
            # The empty placeholder bullet has nothing to continue.
            [[ $trimmed =~ ^[-*]$ ]] && in_entry=0 || in_entry=1
        elif [[ $in_entry -eq 1 ]]; then
            logical="${logical%$'\n'} $trimmed"$'\n'
        else
            logical+="$trimmed"$'\n'
        fi
    done <<<"$section"

    local entries="" has_none=0 text is_bullet prefix upper
    while read -r line; do
        [[ -z $line ]] && continue

        if [[ $line =~ ^[-*]([[:space:]]+(.*))?$ ]]; then
            text="${BASH_REMATCH[2]}"
            is_bullet=1
        else
            text="$line"
            is_bullet=0
        fi
        # A bare "-" is the template's placeholder bullet.
        [[ -z $text ]] && continue

        if [[ $text == [Nn][Oo][Nn][Ee] ]]; then
            has_none=1
            continue
        fi
        # "none (CI only)" or "N/A" would otherwise publish as an Improved entry.
        if [[ $text =~ ^([Nn][Oo][Nn][Ee]|[Nn]/?[Aa])([^A-Za-z]|$) ]]; then
            errors+="write a lone 'none' for internal-only changes: $line"$'\n'
            continue
        fi
        if [[ $is_bullet -eq 0 ]]; then
            errors+="entry is not a '- ' bullet: $line"$'\n'
            continue
        fi

        # Unwrap "**FIX:** x" and "**FIX**: x" so bold prefixes are recognized.
        prefix="$text"
        if [[ $prefix == \*\** || $prefix == __* ]]; then
            prefix="${prefix:2}"
            prefix="${prefix/\*\*:/:}"
            prefix="${prefix/:\*\*/:}"
            prefix="${prefix/__:/:}"
            prefix="${prefix/:__/:}"
        fi
        if [[ $prefix =~ ^([A-Za-z][A-Za-z ]*):[[:space:]]*(.*)$ ]]; then
            upper=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
            case "$upper" in
                BREAKING | "BREAKING CHANGE" | "BREAKING CHANGES") upper=BREAKING ;;
            esac
            case "$upper" in
                BREAKING | NEW | FIX)
                    if [[ -z ${BASH_REMATCH[2]} ]]; then
                        errors+="empty $upper entry"$'\n'
                    else
                        entries+="$upper$TAB${BASH_REMATCH[2]}"$'\n'
                    fi
                    continue
                    ;;
            esac
            # All caps before a colon reads as a prefix attempt, so reject it rather than
            # silently filing it under Improved.
            if [[ ${BASH_REMATCH[1]} == "$upper" ]]; then
                errors+="unknown prefix '${BASH_REMATCH[1]}:' (use BREAKING:, NEW:, FIX:, or no prefix)"$'\n'
                continue
            fi
        fi
        entries+="IMPROVED$TAB$text"$'\n'
    done <<<"$logical"

    if [[ $has_none -eq 1 && -n $entries ]]; then
        errors+="'none' cannot be combined with entries"$'\n'
    elif [[ $has_none -eq 0 && -z $entries && -z $errors ]]; then
        errors+="section is empty — add an entry, or 'none' for internal-only changes"$'\n'
    fi

    if [[ -n $errors ]]; then
        printf '%s' "$errors" >&2
        return 1
    fi
    if [[ $has_none -eq 1 ]]; then
        echo NONE
    else
        printf '%s' "$entries"
    fi
}

check() {
    local out
    if out=$(parse_note 2>&1 >/dev/null); then
        echo "Release note OK"
        return 0
    fi
    local prefix=""
    [[ ${GITHUB_ACTIONS:-} == true ]] && prefix="::error title=Release note::"
    while IFS= read -r line; do
        echo "${prefix}Release note: $line" >&2
    done <<<"$out"
    return 1
}

build() {
    local tag=$1 prev=${2:-} repo
    [[ -n $prev ]] || prev=$(git describe --tags --abbrev=0 "$tag^")
    repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}

    # One "<CATEGORY>\t- <text> (#N)" line per entry, in commit order.
    local all="" seen=" " sha pr number title body parsed category text
    for sha in $(git rev-list --reverse "$prev..$tag"); do
        pr=$(gh api "repos/$repo/commits/$sha/pulls" \
            --jq '[.[] | select(.merged_at != null)] | first // empty | .number, .title, (.body // "")')
        # Commits with no PR are the auto-release version bumps.
        [[ -z $pr ]] && continue
        {
            read -r number
            read -r title
            body=$(cat)
        } <<<"$pr"

        # Rebase merges put several commits on main for one PR.
        case "$seen" in *" $number "*) continue ;; esac
        seen+="$number "

        # A PR that predates the template, or slipped past the gate, still appears — never fail the release over it.
        parsed=$(parse_note <<<"$body" 2>/dev/null) || parsed="IMPROVED$TAB$title"
        [[ $parsed == NONE ]] && parsed="INTERNAL$TAB$title"
        while IFS="$TAB" read -r category text; do
            all+="$category$TAB- $text (#$number)"$'\n'
        done <<<"$parsed"
    done

    print_group "## ⚠️ Breaking changes" BREAKING "$all"
    print_group "## ✨ New" NEW "$all"
    print_group "## 🐛 Fixed" FIX "$all"
    print_group "## 🔧 Improved" IMPROVED "$all"
    print_group "<details>"$'\n'"<summary>Internal changes</summary>" INTERNAL "$all" "</details>"$'\n\n'
    echo "**Full Changelog**: https://github.com/$repo/compare/$prev...$tag"
}

print_group() {
    local header=$1 key=$2 footer=${4:-} items="" category entry
    while IFS="$TAB" read -r category entry; do
        if [[ $category == "$key" ]]; then
            items+="$entry"$'\n'
        fi
    done <<<"$3"
    if [[ -n $items ]]; then
        printf '%s\n\n%s\n%s' "$header" "$items" "$footer"
    fi
}

case "${1:-}" in
    check) check ;;
    build)
        [[ $# -eq 2 || $# -eq 3 ]] || {
            echo "usage: $0 build <tag> [<prev-tag>]" >&2
            exit 64
        }
        build "$2" "${3:-}"
        ;;
    *)
        echo "usage: $0 check < body | $0 build <tag> [<prev-tag>]" >&2
        exit 64
        ;;
esac
