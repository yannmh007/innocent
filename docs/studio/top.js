// Innocent Studio — shown only as the top window. The page starts hidden
// (index.html, "NOT INSIDE ANOTHER PAGE'S FRAME"); this shows it when
// nothing frames it, and otherwise takes the whole window instead. Where the
// framing page forbids even that, the console stays hidden inside it.
if (window.top === window.self) {
  document.getElementById('framed').remove();
} else {
  try { window.top.location.replace(window.self.location.href); } catch (_) { /* stays hidden */ }
}
