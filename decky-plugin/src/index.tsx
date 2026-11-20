// SPDX-License-Identifier: GPL-2.0-only
// The panel of the BC-250 Sleep plugin: install bc250-sleep, pick what Steam's Sleep and Power Off do, with
// what each one draws at the wall, and update the plugin from GitHub releases.
import { ButtonItem, ConfirmModal, DropdownItem, Field, PanelSection, PanelSectionRow, showModal, staticClasses } from "@decky/ui";
import { callable, definePlugin, toaster } from "@decky/api";
import { useEffect, useState } from "react";
import { FiAlertTriangle, FiMoon } from "react-icons/fi";

interface State {
  board: boolean;
  bios: string;
  unlocked: boolean;
  installed: boolean;
  version: string;
  bundled: string;
  sleep: string;
  shutdown: string;
  hibernation: string;
  s3: string;
  modules: string;
  log: string;
}

interface Result {
  ok: boolean;
  log: string;
}

interface Release {
  tag: string;
  version: string;
  plugin_url?: string;
  error?: string;
}

const getState = callable<[], State>("get_state");
const setSleep = callable<[mode: string], Result>("set_sleep");
const setShutdown = callable<[mode: string], Result>("set_shutdown");
const install = callable<[], Result>("install");
const uninstall = callable<[], Result>("uninstall");
const rebuild = callable<[], Result>("rebuild");
const reboot = callable<[], void>("reboot");
const latestRelease = callable<[], Release>("latest_release");
const installPlugin = callable<[url: string, tag: string], Result>("install_plugin");

const toast = (body: string) => toaster.toast({ title: "BC-250 Sleep", body });

// 1.10.0 is newer than 1.9.2.
const newer = (a: string, b: string) => {
  const x = a.split(".").map(Number);
  const y = b.split(".").map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  }
  return false;
};

// Decky's own installer (as its store): asks, swaps the files and reloads this plugin alone. Without it, the
// backend swaps them and restarts Decky. The plugin carries the package: once the new version answers, an
// installed package is updated from it.
async function updatePlugin(release: Release, installed: boolean) {
  const decky = (window as any).DeckyBackend;
  if (decky?.call) {
    await decky.call("utilities/install_plugin", release.plugin_url!, "BC-250 Sleep", release.version, "", 2);
    // This panel is the old version's: wait for the new one (the user confirms Decky's prompt first) and
    // have Decky show it in its place, as when the panel is opened.
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      try {
        if ((await getState()).bundled === release.version) {
          if (installed) {
            const r = await install();
            toast(r.ok ? `Updated to ${release.version}` : r.log || "the package did not update");
          } else {
            toast(`Plugin updated to ${release.version}`);
          }
          const state = (window as any).DeckyPluginLoader?.deckyState;
          if (state?.publicState?.().activePlugin?.name === "BC-250 Sleep") state.setActivePlugin("BC-250 Sleep");
          return;
        }
      } catch {
        // the backend restarts with the new version
      }
    }
    return;
  }
  const r = await installPlugin(release.plugin_url!, release.tag);
  toast(r.ok ? "Updated, Decky restarts; then press Update in the panel" : r.log || "failed");
}

// What the board draws at the wall in each state, measured on one board with a wall-plug meter.
const WATTS: Record<string, number> = { s3: 10, hibernate: 5.5, wake: 5 };
const HOURS_PER_MONTH = 730;
const kwh = (mode: string) => ((WATTS[mode] * HOURS_PER_MONTH) / 1000).toFixed(1);

const SLEEPS: [string, string][] = [
  ["s3", "Sleep"],
  ["hibernate", "Hibernation"],
];
const SHUTDOWNS: [string, string][] = [
  ["wake", "Gamepad turns it on"],
  ["default", "Normal power off"],
];
const SLEEP_TEXT: Record<string, string> = {
  s3: "Wakes in about 5 seconds, your game right where you left it",
  hibernate: "Saves everything to the disk and switches off: about a minute to go to sleep, 20 seconds to wake. Your game is still there",
};
const SHUTDOWN_TEXT: Record<string, string> = {
  wake: "Press a button on the gamepad to switch the board on",
  default: "Switches the board off completely; the gamepad cannot switch it on",
};
const describe = (text: Record<string, string>, mode: string) =>
  WATTS[mode] === undefined ? text[mode] ?? "" : `${text[mode]}. About ${kwh(mode)} kWh a month.`;
const options = (list: [string, string][]) =>
  list.map(([data, label]) => ({ data, label: WATTS[data] === undefined ? label : `${label} · ${WATTS[data]} W` }));

function Content() {
  const [state, setState] = useState<State | null>(null);
  const [release, setRelease] = useState<Release | null>(null);
  const [busy, setBusy] = useState("");

  const refresh = async () => setState(await getState());
  useEffect(() => {
    refresh();
    latestRelease().then(setRelease);
  }, []);

  const run = async (what: string, action: () => Promise<Result>, done: string) => {
    setBusy(what);
    try {
      const r = await action();
      toast(r.ok ? done : r.log || "failed");
    } finally {
      setBusy("");
      await refresh();
    }
  };

  if (!state)
    return (
      <PanelSection>
        <PanelSectionRow>
          <Field label="Loading..." />
        </PanelSectionRow>
      </PanelSection>
    );
  if (!state.board)
    return (
      <PanelSection>
        <PanelSectionRow>
          <Field label="Not an AMD BC-250" description="This plugin is for the AMD BC-250 board only." />
        </PanelSectionRow>
      </PanelSection>
    );

  const needsReboot = [state.hibernation, state.s3].some((t) => t.includes("next reboot"));
  const update = state.installed && state.bundled && state.bundled !== state.version;
  const pluginUpdate = !!release?.plugin_url && newer(release.version, state.bundled);
  // After a system update the modules are built again at the next boot; this is when that failed.
  const modulesMissing = state.modules.startsWith("not built");
  // What this boot cannot do, or does only partly: shown one by one; nothing to show is one line "Ready".
  const off = (t: string) => t.replace(/^off: /, "");
  const problems: [string, string][] = [];
  if (!state.s3.startsWith("ready")) problems.push(["Sleep does not work", off(state.s3)]);
  else if (state.s3.includes("old way")) problems.push(["Sleep closes games", "On this kernel the graphics driver has to be stopped for it"]);
  if (!state.hibernation.startsWith("ready")) problems.push(["Hibernation does not work", off(state.hibernation)]);
  if (!state.modules.startsWith("ready")) problems.push(["Kernel modules", state.modules]);
  if (state.bios && state.bios !== "P3.00") problems.push([`BIOS ${state.bios}`, "Sleep is known to work on P3.00-based BIOSes only"]);

  const checkUpdates = async () => {
    if (pluginUpdate) {
      setBusy("plugin");
      try {
        await updatePlugin(release!, state.installed);
      } catch (e) {
        toast(String(e));
      }
      setBusy("");
      await refresh();
      return;
    }
    setBusy("check");
    const r = await latestRelease();
    setRelease(r);
    setBusy("");
    toast(r.error ? `No connection to GitHub: ${r.error}` : r.plugin_url && newer(r.version, state.bundled) ? `${r.version} is out` : "Up to date");
  };

  if (!state.installed)
    return (
      <PanelSection>
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            disabled={!!busy}
            description="Builds two kernel modules for this kernel and puts Steam's Sleep and Power Off on them. Needs the network; a few minutes, then a reboot."
            onClick={() => run("install", install, "Installed: reboot once for S3")}
          >
            {busy === "install" ? "Installing..." : "Install"}
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>
    );

  return (
    <>
      <PanelSection>
        {update && (
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={!!busy} onClick={() => run("update", install, `Updated to ${state.bundled}`)}>
              {busy === "update" ? "Updating..." : `Update to ${state.bundled}`}
            </ButtonItem>
          </PanelSectionRow>
        )}
        <PanelSectionRow>
          <DropdownItem
            layout="below"
            label="Sleep"
            description={
              <>
                {describe(SLEEP_TEXT, state.sleep)}
                {state.sleep === "s3" && state.unlocked && (
                  <div style={{ color: "#e8b93a", marginTop: "6px" }}>
                    <FiAlertTriangle style={{ marginRight: "6px", verticalAlign: "-2px" }} />
                    Wakes up with 6 of 8 cores: the BIOS starts only its own six after sleep. All 8 are back
                    after a reboot. Hibernation keeps all 8.
                  </div>
                )}
              </>
            }
            rgOptions={options(SLEEPS)}
            selectedOption={state.sleep}
            disabled={!!busy}
            onChange={(o) => run("sleep", () => setSleep(o.data), "Sleep changed")}
          />
        </PanelSectionRow>
        <PanelSectionRow>
          <DropdownItem
            layout="below"
            label="Power Off"
            description={describe(SHUTDOWN_TEXT, state.shutdown)}
            rgOptions={options(SHUTDOWNS)}
            selectedOption={state.shutdown}
            disabled={!!busy}
            onChange={(o) => run("shutdown", () => setShutdown(o.data), "Power Off changed")}
          />
        </PanelSectionRow>
      </PanelSection>

      <PanelSection title="This boot">
        {problems.length === 0 ? (
          <PanelSectionRow>
            <Field label="Ready" description="Sleep and hibernation both work" />
          </PanelSectionRow>
        ) : (
          problems.map(([label, text]) => (
            <PanelSectionRow key={label}>
              <Field label={label} description={text} />
            </PanelSectionRow>
          ))
        )}
        {modulesMissing && (
          <PanelSectionRow>
            <ButtonItem layout="below" disabled={!!busy} onClick={() => run("rebuild", rebuild, "Modules built")}>
              {busy === "rebuild" ? "Building..." : "Build for this kernel"}
            </ButtonItem>
          </PanelSectionRow>
        )}
        {needsReboot && (
          <PanelSectionRow>
            <ButtonItem
              layout="below"
              onClick={() => showModal(<ConfirmModal strTitle="Reboot" strDescription="Reboot now?" strOKButtonText="Reboot" onOK={() => reboot()} />)}
            >
              Reboot to apply
            </ButtonItem>
          </PanelSectionRow>
        )}
      </PanelSection>

      <PanelSection title="Waking with the gamepad">
        <PanelSectionRow>
          <Field
            description="Works only with a gamepad or its receiver in a blue USB 3.0 port. Bluetooth gamepads cannot wake the board."
            focusable
          />
        </PanelSectionRow>
      </PanelSection>

      <PanelSection title={`Version ${state.version || state.bundled}`}>
        <PanelSectionRow>
          <ButtonItem layout="below" disabled={!!busy} onClick={checkUpdates}>
            {busy === "plugin" ? "Updating..." : busy === "check" ? "Checking..." : pluginUpdate ? `Update to ${release!.version}` : "Check for updates"}
          </ButtonItem>
        </PanelSectionRow>
        {release?.error && (
          <PanelSectionRow>
            <Field label="No connection to GitHub" description={release.error} />
          </PanelSectionRow>
        )}
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            disabled={!!busy}
            onClick={() =>
              showModal(
                <ConfirmModal
                  strTitle="Uninstall"
                  strDescription="Sleep and Power Off go back to the system's own. Your settings stay in /etc/bc250-sleep."
                  strOKButtonText="Uninstall"
                  onOK={() => run("uninstall", uninstall, "Uninstalled")}
                />,
              )
            }
          >
            {busy === "uninstall" ? "Uninstalling..." : "Uninstall"}
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>
    </>
  );
}

export default definePlugin(() => ({
  name: "BC-250 Sleep",
  titleView: <div className={staticClasses.Title}>BC-250 Sleep</div>,
  content: <Content />,
  icon: <FiMoon />,
}));
