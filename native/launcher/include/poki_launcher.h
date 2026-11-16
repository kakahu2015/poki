// PokiLauncher: gets the WebDriverAgent runner up on this phone and keeps it up; pairs the phone with
// itself (iOS 27). docs/ios-core.md §3. Every string passed in is UTF-8 and only read during the call;
// event strings are valid only during the callback, which runs on a launcher thread.
#ifndef POKI_LAUNCHER_H
#define POKI_LAUNCHER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PokiLauncher PokiLauncher;
typedef struct PokiPairing PokiPairing;
typedef void (*poki_event_cb)(void *context, const char *event_json);

// config_json: {"device_address": "10.7.0.1", "pairing_file": "...", "host_name": "Poki",
//   "ddi_dir": "...", "runner_bundle": null, "wda_host": "127.0.0.1", "wda_port": 8100}
// Events: {"state": "idle|connecting|pairing|mounting_ddi|launching|running|waiting_network|failed",
//   "attempt": n, "since_ms": n, "pairing": "remote|lockdown", "ios": "...", "runner": "...",
//   "detail": "...", "fix": "..."}
PokiLauncher *poki_launcher_new(const char *config_json, poki_event_cb cb, void *context);
int32_t poki_launcher_start(PokiLauncher *launcher);
void poki_launcher_restart(PokiLauncher *launcher);
void poki_launcher_stop(PokiLauncher *launcher);
char *poki_launcher_status(PokiLauncher *launcher);
void poki_launcher_free(PokiLauncher *launcher);
void poki_string_free(char *text);
// The phone's remote pairing port, as found in Bonjour (_remotepairing._tcp): iOS moves the service
// off 49152 when it starts it again. Every later connection goes there. 0 means 49152.
void poki_set_remote_pairing_port(uint16_t port);
// true while the app looks for a moved remote pairing port in Bonjour: only then is a refused
// connection reported as a moved port (code "pairing_port"). false: handled as before.
void poki_set_pairing_port_search(bool searching);

// config_json: {"host_name": "Poki", "out_path": "...", "identity_path": "..."}
// Events: {"event": "advertise", "service_type": "_remotepairing-pairable-host._tcp", "instance": "...",
//   "port": n, "txt": {...}} (publish it with Bonjour), {"event": "pin", "pin": "123456"},
//   {"event": "paired", "path": "..."}, {"event": "failed", "detail": "..."}
PokiPairing *poki_pair_start(const char *config_json, poki_event_cb cb, void *context);
void poki_pair_cancel(PokiPairing *pairing);

// request_json: {"device_address": "10.7.0.1", "pairing_file": "...", "host_name": "Poki"}.
// Events: {"event": "result", "ok": true, "value": {"udid": "..."}}, or
// {"event": "result", "ok": false, "error": "...", "code": "..."}.
// Returns -1 when the request is unreadable (no events follow), else 0.
int32_t poki_pairing_check(const char *request_json, poki_event_cb cb, void *context);
// iPhone History tests (native/launcher/src/history.rs): the screen read as text through the
// accessibility audit service, on a tunnel of its own and with no XCTest session.
// request_json: {"op": "read_once", "device_address": "10.7.0.1", "pairing_file": "...",
//   "host_name": "Poki", "include_text": false} or {"op": "run", ..., "interval_ms": 5000,
//   "duration_s": 1800}.
// Events: {"event": "progress", "progress": {"n", "at_s", "ok", "ms", "elements", "app", "changed"}}
// for every read of a run, then one {"event": "result", "ok": true, "value": {...}} or
// {"event": "result", "ok": false, "error": "...", "fix": "...", "code": "..."}.
// Returns -1 when the request is unreadable (no events follow), else 0.
int32_t poki_history_call(const char *request_json, poki_event_cb cb, void *context);
// Ends the run in progress; it answers with what it measured so far.
void poki_history_cancel(void);

#ifdef __cplusplus
}
#endif

#endif
