# Sparkline

Menu-bar app for two DGX Sparks, each powered through a Tapo P110.

![Dashboard](docs/dashboard.png)

Each Spark shows whether the outlet is on, whether the machine is up, live watts, GPU use, memory, the job that is running, and temperatures. The link rows show whether the cable to Spark 1 and the cable between the two Sparks are up, and can run a 10-second speed test.

![Charts](docs/charts.png)

Power and temperature history for the last hour, 24 hours, 7 days, or 30 days. Readings are taken every 10 seconds and kept for a day, with one-minute averages kept for 30 days.

![Widget](docs/widget.png)

The desktop widget shows both Sparks. Shut Down signs in over SSH and switches the plug off only after the machine is confirmed down. If that check fails, the plug stays on.

In Settings, a schedule can shut a Spark down when it has been idle inside a time window, and leave it off until you turn it on. A running job blocks that automatic shutdown. Temperature never shuts a machine down.

## Build

Uses the Xcode at `/Applications/Xcode.app`.

```
make install
```

The app lives in the menu bar. Open the dashboard from there, and Settings with ⌘,.
