# Shared by run_macos.sh and run_ios.sh. Source it; do not run it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/GitHubDashboard.xcodeproj"
SCHEME="GitHubDashboard"
DERIVED="$ROOT/build"
APP_NAME="GitHub Dashboard.app"

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
            GITHUB_ORGS | IGNORED_LOGINS | BUNDLE_ID | DEVELOPMENT_TEAM | GH_TOKEN | IOS_SIMULATOR)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done <"$file"
}

# build <configuration> <destination>
build() {
    local settings=(
        "DASHBOARD_ORGS=${GITHUB_ORGS:-}"
        "DASHBOARD_IGNORED_LOGINS=${IGNORED_LOGINS:-}"
    )
    [[ -n "${BUNDLE_ID:-}" ]] && settings+=("DASHBOARD_BUNDLE_ID=$BUNDLE_ID")
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] && settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")

    echo "Building ($1)…"
    xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" -configuration "$1" \
        -destination "$2" -derivedDataPath "$DERIVED" "${settings[@]}" build
}

bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1"
}
