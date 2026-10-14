# Frontend (step 5, not started)

One HTML/JavaScript app serves both implementations:

- **MATLAB** shows it in a single `uihtml` component (R2023a+), talking through `sendEventToHTMLSource` and `HTMLEventReceivedFcn`.
- **Python** serves it over a local HTTP or WebSocket server.

The boundary is a versioned JSON message protocol: requests, responses and events. It will get its own schema in `schema/`. The app is developed in a normal browser against a mock backend that implements the protocol. All assets are bundled locally, with no CDN, so the app works offline inside `uihtml`.

Planned pieces:

- **Entity table view:** the external HTML entity table component.
- **Option forms:** generated from the JSON Schema in each method declaration (`nansen.method`).
- **Task queue view:** reads and writes `nansen.task` documents.

Image viewers, plots and other figure windows stay native MATLAB or Python; only the main app moves to HTML.
