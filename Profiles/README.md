# FanBar machine profiles

FanBar can export the macOS automatic fan targets it has observed for the current Mac model.
Exported files use the name `fanbar-profile-<model>-v1.json` and can be contributed to this
directory in a future pull request.

The export contains the Mac model identifier, CPU architecture, macOS version, temperatures,
system power, power-source state, macOS thermal-pressure level, fan ranges, and macOS target RPM. It never
contains a serial number, user name, host name, file path, exact timestamp, or application data.

Samples are only learned while macOS owns automatic fan control, including the short system-demand
audits performed by FanBar. Learned values are a conservative safety floor; they never replace
periodic observation of the real macOS target.
