// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.

// Too many type errors in this file.
// @ts-nocheck

import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import Intercom from "@intercom/messenger-js-sdk";
import { getHooks } from "live_svelte";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import posthog from "posthog-js";
import { toast } from "svelte-sonner";
import * as Components from "../svelte/**/*.svelte";
import topbar from "../vendor/topbar";

posthog.init(document.querySelector("body").getAttribute("data-ph-token"), {
  api_host: "https://d2qm7p9dngzyqg.cloudfront.net",
  ui_host: "https://us.posthog.com",
  session_recording: {
    maskAllInputs: false,
  },
});

Intercom({
  app_id: "btt358pc",
  custom_launcher_selector: "#launch-intercom",
});

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: getHooks(Components),
  params: { _csrf_token: csrfToken },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

window.addEventListener("phx:toast", (event) => {
  const attrs = {
    description: event.detail.description,
    duration: event.detail.duration,
  };

  switch (event.detail.kind) {
    case "info":
      toast(event.detail.title, attrs);
      break;
    case "success":
      toast.success(event.detail.title, attrs);
      break;
    case "error":
      toast.error(event.detail.title, attrs);
      break;
  }
});

window.addEventListener("phx:ph-identify", (event) => {
  const { userId, userEmail, userName, accountId, accountName, createdAt } =
    event.detail;

  posthog.identify(userId, {
    email: userEmail,
    name: userName,
    $groups: { account: accountId },
  });

  posthog.group("account", accountId, {
    name: accountName,
  });

  Intercom({
    app_id: "btt358pc",
    user_id: userId,
    name: userName,
    email: userEmail,
    created_at: createdAt,
    company: {
      id: accountId,
      name: accountName,
    },
  });
});

window.addEventListener("phx:ph-reset", () => {
  posthog.reset();
  if (window.Intercom) {
    window.Intercom("shutdown");
    window.Intercom("boot", { app_id: "YOUR_APP_ID" });
  }
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
