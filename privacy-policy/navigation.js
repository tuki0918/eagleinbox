(() => {
  const setupNavigationDrawer = () => {
    const drawer = document.querySelector(".table-of-contents");
    const openButton = document.querySelector(".menu-button");
    const closeButton = document.querySelector(".drawer-close");
    const backdrop = document.querySelector(".drawer-backdrop");
    const header = document.querySelector(".site-header");

    if (!drawer || !openButton || !closeButton || !backdrop || !header) {
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
    const scrollThreshold = 8;
    let lastScrollY = Math.max(window.scrollY, 0);
    let accumulatedScroll = 0;

    const showHeader = () => header.classList.remove("header-hidden");

    const resetScrollTracking = () => {
      lastScrollY = Math.max(window.scrollY, 0);
      accumulatedScroll = 0;
    };

    const updateHeaderVisibility = () => {
      const currentScrollY = Math.max(window.scrollY, 0);

      if (
        !mobileViewport.matches ||
        document.body.classList.contains("drawer-open") ||
        currentScrollY <= header.offsetHeight
      ) {
        showHeader();
        lastScrollY = currentScrollY;
        accumulatedScroll = 0;
        return;
      }

      const scrollDelta = currentScrollY - lastScrollY;
      if (
        (scrollDelta > 0 && accumulatedScroll < 0) ||
        (scrollDelta < 0 && accumulatedScroll > 0)
      ) {
        accumulatedScroll = 0;
      }
      accumulatedScroll += scrollDelta;

      if (accumulatedScroll >= scrollThreshold) {
        header.classList.add("header-hidden");
        accumulatedScroll = 0;
      } else if (accumulatedScroll <= -scrollThreshold) {
        showHeader();
        accumulatedScroll = 0;
      }

      lastScrollY = currentScrollY;
    };

    const closeDrawer = ({ restoreFocus = true } = {}) => {
      document.body.classList.remove("drawer-open");
      openButton.setAttribute("aria-expanded", "false");
      drawer.setAttribute("aria-hidden", "true");
      resetScrollTracking();
      if (restoreFocus) {
        openButton.focus();
      }
    };

    const openDrawer = () => {
      showHeader();
      resetScrollTracking();
      document.body.classList.add("drawer-open");
      openButton.setAttribute("aria-expanded", "true");
      drawer.removeAttribute("aria-hidden");
      closeButton.focus();
    };

    const synchronizeAccessibility = () => {
      if (!mobileViewport.matches) {
        document.body.classList.remove("drawer-open");
        showHeader();
        resetScrollTracking();
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
    window.addEventListener("scroll", updateHeaderVisibility, {
      ...listenerOptions,
      passive: true,
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
