#!/usr/bin/env bash
set -euo pipefail

# Read-only report: accounts followed by the authenticated user whose latest
# visible post is older than one calendar year. Requires curl and jq.

usage() {
  cat <<'EOF'
Usage: ./xffchk.sh [--input responses.json] [--cutoff YYYY-MM-DD] > report.csv

Live mode requires X_ACCESS_TOKEN and either X_USERNAME or X_USER_ID.
X_ACCESS_TOKEN can be an app-only bearer token or an OAuth 2.0 user token.
--input accepts one saved API response or an array of paginated responses.
--cutoff overrides the default: the current UTC time minus one calendar year.
No follow or unfollow request is made.
EOF
}

input=''
cutoff=''
while (($#)); do
  case "$1" in
    --input)
      (($# >= 2)) || { usage >&2; exit 2; }
      input=$2; shift 2 ;;
    --cutoff)
      (($# >= 2)) || { usage >&2; exit 2; }
      [[ $2 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo 'Cutoff must be YYYY-MM-DD' >&2; exit 2; }
      cutoff="${2}T00:00:00Z"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for command in curl jq date mktemp; do
  command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done

if [[ -z $cutoff ]]; then
  if cutoff=$(date -u -v-1y +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
    :
  else
    cutoff=$(date -u -d '1 year ago' +'%Y-%m-%dT%H:%M:%SZ')
  fi
fi

umask 077
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
pages="$tmpdir/pages.json"

if [[ -n $input ]]; then
  jq 'if type == "array" then . else [.] end' "$input" > "$pages"
else
  : "${X_ACCESS_TOKEN:?Set X_ACCESS_TOKEN to your X API bearer token}"
  if [[ -n ${X_USER_ID:-} ]]; then
    [[ $X_USER_ID =~ ^[0-9]{1,19}$ ]] || { echo 'X_USER_ID must be numeric' >&2; exit 2; }
    user_id=$X_USER_ID
  else
    : "${X_USERNAME:?Set X_USERNAME or X_USER_ID}"
    [[ $X_USERNAME =~ ^[A-Za-z0-9_]+$ ]] || { echo 'X_USERNAME has invalid characters' >&2; exit 2; }
    curl --silent --show-error --fail --max-time 60 \
      --header "Authorization: Bearer $X_ACCESS_TOKEN" \
      "https://api.x.com/2/users/by/username/$X_USERNAME" > "$tmpdir/me.json"
    user_id=$(jq -er '.data.id | select(test("^[0-9]{1,19}$"))' "$tmpdir/me.json") || {
      echo 'Could not resolve X_USERNAME to a user ID' >&2
      exit 1
    }
  fi

  token=''
  page_number=0
  while :; do
    page_number=$((page_number + 1))
    page="$tmpdir/page-$page_number.json"
    args=(
      --silent --show-error --fail --max-time 60 --get
      --header "Authorization: Bearer $X_ACCESS_TOKEN"
      --data-urlencode 'max_results=1000'
      --data-urlencode 'user.fields=protected,public_metrics'
      --data-urlencode 'expansions=most_recent_post_id'
      --data-urlencode 'post.fields=created_at'
    )
    if [[ -n $token ]]; then
      args+=(--data-urlencode "pagination_token=$token")
    fi
    curl "${args[@]}" "https://api.x.com/2/users/$user_id/following" > "$page"
    jq -e 'type == "object" and ((.errors // []) | length == 0)' "$page" >/dev/null || {
      echo "API response on page $page_number contains errors; report not generated" >&2
      exit 1
    }
    next_token=$(jq -r '.meta.next_token // empty' "$page")
    if [[ -z $next_token ]]; then break; fi
    if [[ $next_token == "$token" ]]; then
      echo 'API returned a repeated pagination token; report not generated' >&2
      exit 1
    fi
    token=$next_token
  done
  jq -s '.' "$tmpdir"/page-*.json > "$pages"
fi

jq -e '
  type == "array" and all(.[];
    type == "object" and
    ((.errors // []) | length == 0) and
    (.data == null or (.data | type == "array"))
  )
' "$pages" >/dev/null || { echo 'Invalid or partial API response; report not generated' >&2; exit 1; }

echo "Cutoff (UTC): $cutoff" >&2
jq -r --arg cutoff "$cutoff" '
  def timestamp: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  [ .[] | . as $page
    | (($page.includes.posts // $page.includes.tweets // []) | map({key: .id, value: .created_at}) | from_entries) as $posts
    | $page.data[]?
    | . as $user
    | ($user.most_recent_post_id // $user.most_recent_tweet_id // null) as $post_id
    | (if $post_id then $posts[$post_id] else null end) as $posted_at
    | {
        status: (if $posted_at != null then
                  (if ($posted_at | timestamp) < ($cutoff | timestamp) then "inactive" else "active" end)
                  elif $post_id == null and $user.public_metrics.post_count == 0 then "no_posts"
                  else "unknown" end),
        id: $user.id,
        username: $user.username,
        name: $user.name,
        latest_post_at: ($posted_at // ""),
        profile_url: ("https://x.com/" + $user.username),
        latest_post_url: (if $post_id then "https://x.com/i/status/" + $post_id else "" end)
      }
  ] | sort_by([(if .status == "inactive" or .status == "no_posts" then 0 elif .status == "unknown" then 1 else 2 end), .latest_post_at, .username])
  | (["status", "id", "username", "name", "latest_post_at", "profile_url", "latest_post_url"] | @csv),
    (.[] | [.status, .id, .username, .name, .latest_post_at, .profile_url, .latest_post_url] | @csv)
' "$pages" > "$tmpdir/report.csv"

cat "$tmpdir/report.csv"

jq -r --arg cutoff "$cutoff" '
  def timestamp: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  [ .[] | . as $page
    | (($page.includes.posts // $page.includes.tweets // []) | map({key: .id, value: .created_at}) | from_entries) as $posts
    | $page.data[]?
    | (.most_recent_post_id // .most_recent_tweet_id // null) as $post_id
    | (if $post_id then $posts[$post_id] else null end) as $posted_at
    | if $posted_at != null then
        (if ($posted_at | timestamp) < ($cutoff | timestamp) then "inactive" else "active" end)
      elif $post_id == null and .public_metrics.post_count == 0 then "no_posts"
      else "unknown" end
  ] | group_by(.) | map("\(.[0]): \(length)") | join(", ")
' "$pages" >&2
