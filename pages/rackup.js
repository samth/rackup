(function () {
  function setupCopy(btnId, sourceId) {
    var btn = document.getElementById(btnId);
    var source = document.getElementById(sourceId);
    if (btn && source && navigator.clipboard) {
      btn.addEventListener("click", function (event) {
        event.preventDefault();
        navigator.clipboard.writeText(source.textContent).then(function () {
          var old = btn.innerHTML;
          btn.innerHTML = "Copied";
          setTimeout(function () {
            btn.innerHTML = old;
          }, 1200);
        });
      });
    }
  }
  setupCopy("copy-install-cmd", "install-cmd");
  setupCopy("copy-paranoid-cmd", "paranoid-cmd");
}());
