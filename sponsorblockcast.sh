#!/bin/sh

SBCPOLLINTERVAL="${SBCPOLLINTERVAL:-1}"
SBCSCANINTERVAL="${SBCSCANINTERVAL:-300}"
SBCDIR="${SBCDIR:-/tmp/sponsorblockcast}"
SBCCATEGORIES="${SBCCATEGORIES:-sponsor}"

# Format categories for curl by quoting words, replacing spaces with commas and surrounding with brackets
categories="[$(echo "$SBCCATEGORIES" | sed 's/[^ ]\+/"&"/g;s/\s/,/g')]"

# Make sure the watch() subprocess gets killed if the parent script is terminated. 
trap "exit" INT TERM
trap "kill 0" EXIT

# Create and cleanup temporary directory
[ -e "$SBCDIR" ] && rm -r "$SBCDIR"
mkdir "$SBCDIR" || exit 1
cd    "$SBCDIR" || exit 1

# Download skippable segments data from SponsorBlock
get_segments () {
  id=$1
  if [ -n "$id" ] && [ ! -f "$id".json ]
  then
    curl -fs --get "https://sponsor.ajay.app/api/skipSegments" --data "videoID=$id" --data "categories=$categories" > "$id".json
  fi
}

# Test if the input has changed since the last time this function was called
has_variable_changed () {
  if [ "$*" = "$prev_value" ] ; then
    return 1 # not changed
  else
    prev_value=$*
    return 0 # changed
  fi
}

# Fallback search method in case the Chromecast device fails to pass the videoId to go-chromecast
get_videoID_by_API () {
  if [ -n "$SBCYOUTUBEAPIKEY" ] ; then
    curl -fs --get "https://www.googleapis.com/youtube/v3/search" --data-urlencode "q=\"$video_artist\"+intitle:\"$video_title\"" --data-urlencode "maxResults=1" --data-urlencode "key=$SBCYOUTUBEAPIKEY" \
    | jq -j '.items[0].id.videoId'
  else
    echo "Unable to identify Video ID. Try setting \$SBCYOUTUBEAPIKEY=\"your private Youtube API Key\" to enable fallback method."
    return 1
  fi
}

watch () {
  uuid=$1
  go-chromecast watch -u "$uuid" --interval "$SBCPOLLINTERVAL" \
  | while read -r status; do
    if echo "$status" | grep -q "YouTube (PLAYING), title="
    then
      video_id=$(echo "$status" | grep -oP "id=\"\K[^\"]+")
      video_title=$(echo "$status" | grep -oP "title=\"\K[^\"]+")
      video_artist=$(echo "$status" | grep -oP "artist=\"\K[^\"]+")

      if [ -z "$video_id" ]
      then
        if has_variable_changed "$video_title $video_artist"
          # Avoid repeating the API search unless the playing video has changed.
        then
          video_id="$(get_videoID_by_API)" && prev_video_id="$video_id"
        else
          video_id="$prev_video_id"
        fi
      fi

      if [ -n "$video_id" ]; then # Only try to continue if the video has been identified successfully
        get_segments "$video_id"
        progress=$(echo "$status" | grep -oP 'remaining=\K[^s]+')
        jq --raw-output '.[] | (.segment|map_values(tostring)|join(" ")) + " " + .category' "$video_id".json 2> /dev/null |\
        while read -r start end category; do
          if [ "$(echo "($progress > $start) && ($progress < ($end - 5))" | bc)" -eq 1 ]
          then
            echo "Skipping $category from $start -> $end on $uuid"
            go-chromecast -u "$uuid" seek-to "$end"
          fi
        done
      fi

    fi
  done;
}

scan_chromecasts() {
  go-chromecast ls | grep -v 'device="Google Cast Group"' | grep -oP 'uuid="\K[^"]+' | sed 's/-//g;' > devices
}

pid_exists () {
  kill -0 "$1" 2>/dev/null
}

# Takes a variable name and returns its value
expand () {
  eval "echo \$$1"
}

while :
do
  scan_chromecasts
  while read -r uuid; do
    uuid_var="sbc$uuid" # Create a dynamically named pid variable for each $uuid
    if [ -z "$(expand "$uuid_var")" ] || ! pid_exists "$(expand "$uuid_var")" # If the pid variable is empty or the pid does not exist; prevents duplicate watch subprocesses
    then
      watch "$uuid" & # Watch in the background
      eval "$uuid_var=$!" # Save the pid into the variable for each $uuid
      echo watching "$uuid", pid="$(expand "$uuid_var")" # Log
    fi
  done < devices
  sleep "$SBCSCANINTERVAL"
done

