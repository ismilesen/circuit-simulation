/**
 * upload_bridge.js
 *
 * Provides the two globals that upload_panel.gd expects on web builds:
 *   window.godotUploadQueue       – Array of queue items (see formats below)
 *   window.godotUploadOpenPicker() – opens the browser file picker
 *
 * Queue item formats (upload_panel.gd handles both):
 *   Batch form (preferred — pushed by the file picker):
 *     { type: "batch", files: [ { name, size, type, base64, error }, ... ] }
 *   Legacy single-file form (pushed by drag-and-drop, one per file):
 *     { name, base64, error? }
 *
 * The panel validates "at most 1 xchem (.sch/.sym) + at most 1 spice
 * (.spice/.cir/.net/.txt) per upload" on the GDScript side, so this file
 * only needs to deliver the bytes honestly.
 *
 * Include this script in the exported HTML BEFORE the Godot engine boots.
 * In Godot's Web export settings → HTML → "Head Include", add:
 *   <script src="upload_bridge.js"></script>
 *
 * Then copy this file into the same folder as the exported .html file.
 */

(function () {
  "use strict";

  // Queue polled every frame by upload_panel.gd via JavaScriptBridge.eval().
  window.godotUploadQueue = [];

  // File extensions the picker offers. Matches upload_panel.gd expectations
  // plus workspace zips for Load Workspace.
  var ACCEPT_EXTS = [
    ".sch", ".sym",
    ".spice", ".cir", ".net", ".txt",
    ".zip", ".cvw.zip"
  ];

  // Encode bytes to base64 in chunks to avoid stack overflow on large files.
  function _bytesToBase64(bytes) {
    var CHUNK = 0x8000;
    var binary = "";
    for (var i = 0; i < bytes.length; i += CHUNK) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(binary);
  }

  // Read a File and return a {name, size, type, base64, error} entry.
  function _fileToEntry(file) {
    return file.arrayBuffer()
      .then(function (buf) {
        var bytes = new Uint8Array(buf);
        return {
          name: file.name,
          size: file.size,
          type: file.type || "",
          base64: _bytesToBase64(bytes),
          error: ""
        };
      })
      .catch(function (err) {
        return {
          name: (file && file.name) || "unknown",
          size: (file && file.size) || 0,
          type: (file && file.type) || "",
          base64: "",
          error: String(err)
        };
      });
  }

  // Called by upload_panel.gd when the user clicks the Upload button.
  // Delivers the whole picker selection as ONE batch so the GDScript side
  // can enforce "at most one xchem + at most one spice per upload" atomically.
  window.godotUploadOpenPicker = function () {
    var input = document.createElement("input");
    input.type = "file";
    input.multiple = true;
    input.accept = ACCEPT_EXTS.join(",");

    input.addEventListener("change", function (e) {
      var files = Array.from(e.target.files || []);
      if (input.parentNode) {
        input.parentNode.removeChild(input);
      }
      if (files.length === 0) return;

      Promise.all(files.map(_fileToEntry)).then(function (entries) {
        window.godotUploadQueue.push({
          type: "batch",
          files: entries
        });
      });
    });

    // Must be in the DOM for some browsers to fire the change event.
    input.style.display = "none";
    document.body.appendChild(input);
    input.click();
  };

  // Drag-and-drop onto the Godot canvas: also deliver as a single batch so
  // a user dropping one xchem + one spice together is treated as one project.
  function _setupDragDrop() {
    var canvas = document.getElementById("canvas");
    if (!canvas) {
      setTimeout(_setupDragDrop, 500);
      return;
    }

    canvas.addEventListener("dragover", function (e) {
      e.preventDefault();
      e.stopPropagation();
      if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    });

    canvas.addEventListener("drop", function (e) {
      e.preventDefault();
      e.stopPropagation();
      var files = Array.from((e.dataTransfer && e.dataTransfer.files) || []);
      if (files.length === 0) return;

      Promise.all(files.map(_fileToEntry)).then(function (entries) {
        window.godotUploadQueue.push({
          type: "batch",
          files: entries
        });
      });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", _setupDragDrop);
  } else {
    _setupDragDrop();
  }
})();
