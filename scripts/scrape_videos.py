#!/usr/bin/env python3
import os
import sys
import json
import time
import urllib.request

WORKSPACE_DIR = "/Users/rajesh/Desktop/vibe-coding/My-Trainer"
VIDEOS_DIR = os.path.join(WORKSPACE_DIR, "videos")
CATALOG_PATH = os.path.join(WORKSPACE_DIR, "exercise-catalog.json")

# Mapping exercise slug -> direct Wikimedia Upload URL
DIRECT_URLS = {
    "back-squat": "https://upload.wikimedia.org/wikipedia/commons/5/5c/Squat_-_exercise_demonstration_video.webm",
    "deadlift": "https://upload.wikimedia.org/wikipedia/commons/6/62/Deadlift_-_exercise_demonstration_video.webm",
    "bench-press": "https://upload.wikimedia.org/wikipedia/commons/d/df/Bench_press_-_exercise_demonstration_video.webm",
    "barbell-row": "https://upload.wikimedia.org/wikipedia/commons/b/b2/Bent-over_row_-_exercise_demonstration_video.webm",
    "overhead-press": "https://upload.wikimedia.org/wikipedia/commons/6/69/Shoulder_press_-_exercise_demonstration_video.webm",
    "pull-up": "https://upload.wikimedia.org/wikipedia/commons/1/15/Pull-ups_-_exercise_demonstration_video.webm",
    "hanging-leg-raise": "https://upload.wikimedia.org/wikipedia/commons/b/bf/Leg_raises_-_exercise_demonstration_video.webm",
    "incline-db-press": "https://upload.wikimedia.org/wikipedia/commons/8/80/Incline_press_-_exercise_demonstration_video.webm",
    "leg-curl": "https://upload.wikimedia.org/wikipedia/commons/1/14/Muscle_Strengthening_at_the_Gym_-_Leg_Curl.webm",
    "leg-press": "https://upload.wikimedia.org/wikipedia/commons/8/83/Muscle_Strengthening_at_the_Gym_-_Seated_Leg_Press.webm",
    "machine-chest-press": "https://upload.wikimedia.org/wikipedia/commons/7/70/Muscle_Strengthening_at_the_Gym_-_Chest_Press.webm",
    "goblet-squat": "https://upload.wikimedia.org/wikipedia/commons/c/c3/Kettlebell_Goblet_Squat.webm",
    "lat-pulldown": "https://upload.wikimedia.org/wikipedia/commons/0/03/Common_Lat_Pulldown_Mistakes.webm",
    "barbell-curl": "https://upload.wikimedia.org/wikipedia/commons/e/ec/Video_of_EZ_Bar_Curl_and_Straight_Bar_Curl.webm",
    "db-bench-press": "https://upload.wikimedia.org/wikipedia/commons/c/c0/Video_showing_how_to_perform_the_dumbbell_bench_press_and_the_dumbbell_incline_bench_press.webm",
    "push-up": "https://upload.wikimedia.org/wikipedia/commons/0/0c/Army_Combat_Fitness_Test-_Hand-Release_Push-Up_%28HRP%29_%28Event_3%29.webm"
}

def download_file(url, target_path):
    print(f"Downloading: {url} -> {target_path}")
    headers = {"User-Agent": "MyTrainerApp/1.0 (https://github.com/my-trainer; contact@mytrainer.app)"}
    req = urllib.request.Request(url, headers=headers)
    
    for attempt in range(5):
        try:
            time.sleep(3)
            with urllib.request.urlopen(req) as resp, open(target_path, "wb") as out_file:
                chunk_size = 128 * 1024
                while True:
                    chunk = resp.read(chunk_size)
                    if not chunk:
                        break
                    out_file.write(chunk)
            file_size = os.path.getsize(target_path)
            if file_size < 5000:
                # Check if error html page was returned
                with open(target_path, "r", errors="ignore") as check_f:
                    head = check_f.read(200)
                    if "Wikimedia Error" in head or "429" in head:
                        print(f"Rate limit HTML page detected, backing off... attempt {attempt+1}/5")
                        time.sleep(10 * (attempt + 1))
                        continue
            print(f"Successfully downloaded {target_path} ({file_size} bytes)")
            return True
        except urllib.error.HTTPError as e:
            if e.code == 429:
                print(f"Rate limited (429), backing off... attempt {attempt+1}/5")
                time.sleep(10 * (attempt + 1))
            else:
                print(f"HTTP Error {e.code}: {e.reason}")
        except Exception as e:
            print(f"Download error: {e}, backing off...")
            time.sleep(5)
    return False

def main():
    os.makedirs(VIDEOS_DIR, exist_ok=True)
    
    with open(CATALOG_PATH, "r") as f:
        catalog = json.load(f)
    
    slug_to_item = {item["slug"]: item for item in catalog}
    
    downloaded_count = 0
    updated_catalog_count = 0
    
    for slug, url in DIRECT_URLS.items():
        if slug not in slug_to_item:
            print(f"Warning: slug {slug} not found in catalog")
            continue
            
        local_filename = f"{slug}.webm"
        local_filepath = os.path.join(VIDEOS_DIR, local_filename)
        rel_video_path = f"videos/{local_filename}"
        
        if not os.path.exists(local_filepath) or os.path.getsize(local_filepath) == 0:
            if download_file(url, local_filepath):
                downloaded_count += 1
        else:
            print(f"Already downloaded: {local_filename} ({os.path.getsize(local_filepath)} bytes)")
            
        slug_to_item[slug]["video_url"] = rel_video_path
        updated_catalog_count += 1
        
    with open(CATALOG_PATH, "w") as f:
        json.dump(catalog, f, indent=2)
        f.write("\n")
        
    print(f"\nFinished! Downloaded {downloaded_count} new video files.")
    print(f"Updated {updated_catalog_count} catalog items in {CATALOG_PATH}.")

if __name__ == "__main__":
    main()

