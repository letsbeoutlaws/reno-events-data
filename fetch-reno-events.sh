#!/bin/bash
# ============================================================
# fetch-reno-events.sh
# Automated Reno events scraper using Claude Code
# Schedule with cron: 0 6 * * * /path/to/fetch-reno-events.sh
# ============================================================

set -euo pipefail

# --- Configuration ---
PROJECT_DIR="$HOME/reno-events-project"
OUTPUT_FILE="$PROJECT_DIR/data/events.json"
LOG_FILE="$PROJECT_DIR/logs/fetch-$(date +%Y%m%d).log"
BACKUP_DIR="$PROJECT_DIR/data/backups"

# Create directories if they don't exist
mkdir -p "$PROJECT_DIR/data/backups" "$PROJECT_DIR/logs"

# Backup previous data
if [ -f "$OUTPUT_FILE" ]; then
    cp "$OUTPUT_FILE" "$BACKUP_DIR/events-$(date +%Y%m%d-%H%M%S).json"
fi

echo "=== Reno Events Fetch: $(date) ===" >> "$LOG_FILE"

# --- Mac-compatible date formatting ---
TODAY=$(date +%Y-%m-%d)
YEAR=$(date +%Y)
MONTH=$(date "+%B")
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S%z)

# --- Run Claude Code with the scraping prompt ---
claude --model claude-haiku-4-5-20251001 --allowedTools "WebSearch,WebFetch" -p "
You are an automated event data collector for Reno, Nevada.

TODAY'S DATE: $TODAY

TASK: Search the web for events and things to do in Reno, NV this week and the upcoming weekend. Use multiple searches to be thorough:
1. Search 'things to do this week Reno NV $YEAR'
2. Search 'Reno events this weekend $MONTH $YEAR'  
3. Search 'Reno concerts shows $MONTH $YEAR'
4. Search 'Reno family events kids $MONTH $YEAR'
5. Search for events on specific sites like visitrenotahoe.com, thisisreno.com, renothisweek.com
6. IMPORTANT: Fetch the page https://nvmoms.com/upcoming-events/northern-nevada/ — this is the BEST source for daily family/kids events. Extract EVERY unique event listed for the next 10 days. This includes things like: story times, toddler classes, mommy-and-me yoga, music classes, LEGO clubs, art clubs, family skate nights, steam train rides, baby groups, tumbling classes, swim lessons, play-and-learn sessions, museum toddler hours, family bingo, and more.
7. Search 'Reno library story time schedule $MONTH $YEAR'
8. Search 'Reno Sparks kids activities classes $MONTH $YEAR'

PRIORITY: We want SPECIFIC daily events (story time at 10am at the library, toddler yoga at 9:30am), not just broad suggestions like 'visit the museum'. If a recurring event happens on specific days, list each occurrence as a separate event with its specific date.

For EACH event found, extract:
- name: Event name
- category: One of [Music, Sports, Comedy, Festival, Food & Drink, Entertainment, Education, Outdoors, Art, Nightlife, Community, Other]
- tags: An array of 3-6 lowercase tags that describe the event. Pick from these options (use as many as fit): family, kids, toddlers, babies, teens, outdoors, indoors, food, nightlife, live music, date night, free entry, budget friendly, downtown, western, sports, comedy, science, art, walking, day trip, lake tahoe, animals, hands-on, rainy day, show, college, craft beer, wine, storytime, classes, yoga, swimming, library, museum, arcade, skating, trains, lego, crafts, music class, mommy-and-me, prenatal, parenting. You may also create new relevant tags if none of these fit.
- image_url: If the event listing has an image URL, include it. If not, search for a relevant Unsplash image using this format: https://images.unsplash.com/photo-PHOTO_ID?w=600&h=400&fit=crop — pick a photo that matches the event type (concert, sports, food, etc.). If you cannot find one, use null.
- date: YYYY-MM-DD format
- time: Start time (e.g., '7:00 PM' or 'All Day')
- end_time: End time or end date if multi-day, null if unknown
- location: Venue name
- address: Full address if available
- price: Price or price range as string (e.g., '\$25', '\$10–\$30', 'Free', 'Varies')
- price_note: Any price details (discounts, what's included), null if none
- audience: One of ['All ages', 'Families', 'Adults 18+', 'Adults 21+']
- description: 1-2 sentence description
- source_url: The URL where you found this event
- source_name: Name of the source site

OUTPUT REQUIREMENTS:
- Output ONLY valid JSON, no markdown fences, no explanation
- Use this exact structure:
{
  \"last_updated\": \"$TIMESTAMP\",
  \"city\": \"Reno, NV\",
  \"events\": [
    {
      \"id\": \"evt-001\",
      \"name\": \"...\",
      \"category\": \"...\",
      \"tags\": [\"family\", \"outdoors\"],
      \"image_url\": \"https://...\",
      \"date\": \"...\",
      \"time\": \"...\",
      \"end_time\": null,
      \"location\": \"...\",
      \"address\": \"...\",
      \"price\": \"...\",
      \"price_note\": null,
      \"audience\": \"...\",
      \"description\": \"...\",
      \"source_url\": \"...\",
      \"source_name\": \"...\"
    }
  ]
}

- Generate sequential IDs (evt-001, evt-002, etc.)
- Aim for 40-80 events minimum — there are LOTS of daily recurring events to capture
- Only include events happening within the next 10 days
- Deduplicate — don't list the same event at the same venue on the same date twice
- If you can't find a field, use null (never omit the field)
- For recurring weekly events, list each specific upcoming date as its own entry
" 2>>"$LOG_FILE" > "$OUTPUT_FILE.tmp"

# --- Extract and validate the JSON output ---
# Claude Code may return raw JSON or wrap it in an envelope.
# This handles both cases and strips any non-JSON text.
python3 -c "
import json, sys, re

raw_text = open('$OUTPUT_FILE.tmp').read().strip()

# Try 1: Maybe it's already clean JSON with events
try:
    data = json.loads(raw_text)
    if 'events' in data:
        result = data
    elif 'result' in data:
        result = json.loads(data['result'])
    else:
        raise ValueError('No events or result key found')
except (json.JSONDecodeError, ValueError):
    # Try 2: Extract JSON object from mixed text output
    match = re.search(r'(\{[\s\S]*\"events\"[\s\S]*\})\s*$', raw_text)
    if match:
        result = json.loads(match.group(1))
    else:
        print('ERROR: Could not find events JSON in output')
        sys.exit(1)

assert 'events' in result, 'Missing events key'
assert len(result['events']) > 0, 'No events found'

with open('$OUTPUT_FILE', 'w') as f:
    json.dump(result, f, indent=2)
print('SUCCESS: ' + str(len(result['events'])) + ' events extracted.')
" 2>>"$LOG_FILE" >>"$LOG_FILE"

if [ $? -eq 0 ]; then
    rm -f "$OUTPUT_FILE.tmp"
    echo "Events file saved to $OUTPUT_FILE" >> "$LOG_FILE"
else
    echo "ERROR: Could not extract events from Claude output. Keeping previous data." >> "$LOG_FILE"
    rm -f "$OUTPUT_FILE.tmp"
    exit 1
fi

# --- Push updated data to GitHub ---
cd "$PROJECT_DIR"
git add data/events.json
git commit -m "Update events $TODAY" || true
git push origin main || true

# --- Cleanup old backups (keep 30 days) ---
find "$BACKUP_DIR" -name "events-*.json" -mtime +30 -delete 2>/dev/null || true
find "$PROJECT_DIR/logs" -name "fetch-*.log" -mtime +30 -delete 2>/dev/null || true

echo "=== Fetch complete: $(date) ===" >> "$LOG_FILE"
