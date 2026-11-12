# FanGuard

Menu bar fan control for the M3 Ultra Mac Studio. It keeps the GPU below the temperature where macOS throttles its clock during long LLM prefills.

## Why

With macOS's automatic fan curve, the fans stay around 2,500 rpm. The GPU reaches 80–83 °C, and macOS then cuts its clock from 1,380 MHz to about 620 MHz. The GPU still reports 100% busy, and `pmset` shows nothing, so the throttling is easy to miss.

A sweep with 3 × 64k prompts per fan speed (see jundot/omlx#5121) gave these results:

| Fan speed | Throttled? |
|---|---|
| 3,625 rpm | no, peak 77 °C |
| 3,200 rpm | no, peak 79 °C |
| 2,900 rpm | on run 3 |
| 2,600 rpm | on run 3 |
| automatic | from run 2 |

## How it works

- **`fanguardd`** is a root launchd daemon (`local.fanguard.daemon`).
  - It reads the GPU temperature from `macmon pipe` every 2 s.
  - It sets both fans through the `smc` tool bundled with Stats.app.
  - It runs root-owned copies of all three binaries from `/usr/local/libexec/fanguard`.
- **`FanGuard.app`** is the menu bar app.
  - The menu bar shows the GPU temperature and, optionally, the average fan speed (for example `62° 3050`).
  - It shows GPU temperature, clock, power and fan speed.
  - It edits the curve, and switches between **Curve**, **Max** and **macOS** modes.
- **Shared files** in `/Users/Shared/FanGuard`:
  - `config.json`, written by the app. The daemon clamps every value to a safe range.
  - `status.json`, written by the daemon.

## Default curve

| GPU temperature | Fans |
|---|---|
| below 60 °C | macOS automatic |
| 60 → 65 °C | 2,000 → 3,050 rpm |
| 65 → 90 °C | hold 3,050 rpm |
| 90 °C and above | maximum |

Once boosted, FanGuard hands the fans back to macOS only after the GPU stays below 55 °C for 30 s. The test machine idles at about 48–53 °C, so idle and light use stay with macOS. With this quieter curve, sustained back-to-back 64k prefills throttle mildly (about 8%) from the third prompt; full-speed fans delay that by one prompt.

**During a boost the fans only speed up.** They hold the highest speed reached (up to the target speed, 3,050 rpm by default) through short pauses between prompts, instead of winding down and up again. Full speed drops back to the target only once the GPU is 2 °C under the full-speed point.

**Logs:** `/var/log/fanguard.log` holds the current run or day; it moves to `fanguard.log.1` on each start and at the first message of each day, so there are never more than two files. Every fan speed change is logged.

## Safety

The fans go back to macOS automatic in each of these cases:

- when the daemon starts or stops;
- when it is unloaded or uninstalled;
- after 10 s without sensor data (it then restarts `macmon`);
- whenever the curve, or the **macOS** mode, says so.

## Install, update, remove

```
./build.sh
sudo ./install.sh      # daemon + /Applications/FanGuard.app + login item
sudo ./uninstall.sh    # fans back to automatic; removes everything except /Users/Shared/FanGuard
```

`swift test` runs the curve tests. The daemon log is at `/var/log/fanguard.log`.

Requirements:

- `brew install macmon`
- Stats.app, for its `smc` tool. Keep Stats' own fan control on Automatic, so the two don't fight.
