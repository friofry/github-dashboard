# Shared by run_macos.sh and run_ios.sh. Source it; do not run it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/GitHubDashboard.xcodeproj"
SCHEME="GitHubDashboard"
DERIVED="$ROOT/build"

# Reads known KEY=VALUE pairs from .env without executing it.
load_env() {
    local file="$ROOT/.env" line key value
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        key="${key//[[:space:]]/}"
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            GITHUB_ORGS | IGNORED_LOGINS | BUNDLE_ID | DEVELOPMENT_TEAM | IOS_SIMULATOR)
                printf -v "$key" '%s' "$value"
                ;;
            GH_TOKEN)
                # A token in a plain-text file is easy to leak, so it is no longer read from here.
                if [[ -n "$value" ]]; then
                    echo "Ignoring GH_TOKEN in .env: remove it and use the app's Settings, \`gh auth login\` or an exported GH_TOKEN." >&2
                fi
                ;;
        esac
    done <"$file"
}

# The commit being built, with "-dirty" when the working copy has changes.
commit_id() {
    local id
    id="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null)" || return 0
    if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then id+="-dirty"; fi
    printf '%s' "$id"
}

# build <configuration> <destination>
build() {
    local settings=(
        "DASHBOARD_ORGS=${GITHUB_ORGS:-}"
        "DASHBOARD_IGNORED_LOGINS=${IGNORED_LOGINS:-}"
        "DASHBOARD_COMMIT=$(commit_id)"
    )
    [[ -n "${BUNDLE_ID:-}" ]] && settings+=("DASHBOARD_BUNDLE_ID=$BUNDLE_ID")
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] && settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")

    echo "Building ($1, $(commit_id))…"
    xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" -configuration "$1" \
        -destination "$2" -derivedDataPath "$DERIVED" "${settings[@]}" build
}

# built_app <products folder>, e.g. Release or Debug-iphonesimulator. The name comes from project.yml.
built_app() {
    local app
    app="$(find "$DERIVED/Build/Products/$1" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null)"
    if [[ -z "$app" ]]; then
        echo "No app found in $DERIVED/Build/Products/$1" >&2
        return 1
    fi
    printf '%s' "$app"
}

# plist_value <key> <Info.plist>
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}
