(() => {
  const setupNavigationDrawer = () => {
    const drawer = document.querySelector(".table-of-contents");
    const openButton = document.querySelector(".menu-button");
    const closeButton = document.querySelector(".drawer-close");
    const backdrop = document.querySelector(".drawer-backdrop");

    if (!drawer || !openButton || !closeButton || !backdrop) {
      return;
    }
    if (drawer.dataset.drawerReady === "true") {
      return;
    }
    drawer.dataset.drawerReady = "true";
    window.eagleInboxDrawerCleanup?.();
    const eventController = new AbortController();
    const listenerOptions = { signal: eventController.signal };
    window.eagleInboxDrawerCleanup = () => eventController.abort();
    const mobileViewport = window.matchMedia("(max-width: 900px)");

    const closeDrawer = ({ restoreFocus = true } = {}) => {
      document.body.classList.remove("drawer-open");
      openButton.setAttribute("aria-expanded", "false");
      drawer.setAttribute("aria-hidden", "true");
      if (restoreFocus) {
        openButton.focus();
      }
    };

    const openDrawer = () => {
      document.body.classList.add("drawer-open");
      openButton.setAttribute("aria-expanded", "true");
      drawer.removeAttribute("aria-hidden");
      closeButton.focus();
    };

    const synchronizeAccessibility = () => {
      if (!mobileViewport.matches) {
        document.body.classList.remove("drawer-open");
        openButton.setAttribute("aria-expanded", "false");
        drawer.removeAttribute("aria-hidden");
        return;
      }
      if (!document.body.classList.contains("drawer-open")) {
        drawer.setAttribute("aria-hidden", "true");
      }
    };

    openButton.addEventListener("click", openDrawer, listenerOptions);
    closeButton.addEventListener("click", () => closeDrawer(), listenerOptions);
    backdrop.addEventListener("click", () => closeDrawer(), listenerOptions);
    drawer.querySelectorAll("a").forEach((link) => {
      link.addEventListener(
        "click",
        () => closeDrawer({ restoreFocus: false }),
        listenerOptions
      );
    });
    document.addEventListener(
      "keydown",
      (event) => {
        if (event.key === "Escape" && document.body.classList.contains("drawer-open")) {
          closeDrawer();
        }
      },
      listenerOptions
    );
    mobileViewport.addEventListener("change", synchronizeAccessibility, listenerOptions);
    synchronizeAccessibility();
  };

  window.addEventListener("eagle-inbox:language-ready", setupNavigationDrawer);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setupNavigationDrawer, { once: true });
  } else {
    setupNavigationDrawer();
  }
})();
