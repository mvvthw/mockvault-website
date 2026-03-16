/* ── Mockup Hub – main.js ────────────────────────────────── */
const uxp        = require("uxp");
const { entrypoints } = uxp;
const { localFileSystem: fs } = uxp.storage;
const psApp      = require("photoshop");
const app        = psApp.app;
const core       = psApp.core;
const action     = psApp.action;

// ── State ────────────────────────────────────────────────
let allMockups        = [];   // { name, category, colorable, file, thumbUrl }
let filteredList      = [];
let activeCategory    = "all";
let searchQuery       = "";
let isListView        = false;
let activeColorFilter = null;  // null | "black" | "white" | "colorable"
let favorites         = new Set();  // Set of "category/name" keys
let garmentColor      = "#808080";  // persisted color for colorable mockups
let colorPickerTarget = null;       // mockup pending placement
let selectedFolder    = null;       // user-selected mockups folder

const GARMENT_COLORS = [
  "#ffffff","#e5e5e5","#a3a3a3","#525252","#171717",
  "#1e3a5f","#1d4ed8","#0284c7","#0d9488","#16a34a",
  "#65a30d","#ca8a04","#ea580c","#dc2626","#9f1239",
  "#db2777","#7c3aed","#4c1d95","#92400e","#d4a574",
];

// ── Prefs (persist view/category/filter) ─────────────────
function savePrefs() {
  try {
    localStorage.setItem("mockvault_prefs", JSON.stringify({
      isListView, activeColorFilter, garmentColor
    }));
  } catch {}
}

function loadPrefs() {
  try {
    const p = JSON.parse(localStorage.getItem("mockvault_prefs") || "{}");
    if (p.isListView !== undefined) isListView = p.isListView;
    if (p.activeColorFilter !== undefined) activeColorFilter = p.activeColorFilter;
    if (p.garmentColor !== undefined) garmentColor = p.garmentColor;
  } catch {}
}

// ── Favorites helpers ─────────────────────────────────────
function favKey(mockup) { return `${mockup.category}/${mockup.name}`; }

function loadFavorites() {
  try {
    const saved = localStorage.getItem("mockvault_favorites");
    favorites = new Set(saved ? JSON.parse(saved) : []);
  } catch { favorites = new Set(); }
}

function saveFavorites() {
  try {
    localStorage.setItem("mockvault_favorites", JSON.stringify([...favorites]));
  } catch {}
}

function toggleFavorite(mockup) {
  const key = favKey(mockup);
  if (favorites.has(key)) {
    favorites.delete(key);
    if (activeCategory === "favorites" && favorites.size === 0) {
      activeCategory = "all";
    }
  } else {
    favorites.add(key);
  }
  saveFavorites();

  renderCategories();
  renderGrid();
}

// ── DOM refs ─────────────────────────────────────────────
const mockupGrid    = document.getElementById("mockupGrid");
const emptyState    = document.getElementById("emptyState");
const categoryTabs  = document.getElementById("categoryTabs");
const searchInput   = document.getElementById("searchInput");
const clearSearch   = document.getElementById("clearSearch");
const refreshBtn    = document.getElementById("refreshBtn");
const folderBtn     = document.getElementById("folderBtn");
const mockupCount   = document.getElementById("mockupCount");
const gridViewBtn   = document.getElementById("gridViewBtn");
const listViewBtn   = document.getElementById("listViewBtn");
const colorableBtn    = document.getElementById("colorableBtn");
const blackBtn        = document.getElementById("blackBtn");
const whiteBtn        = document.getElementById("whiteBtn");
const clearFiltersBtn    = document.getElementById("clearFiltersBtn");
const filterToggleBtn    = document.getElementById("filterToggleBtn");
const filterPopout       = document.getElementById("filterPopout");
const filterPopoutWrap   = document.getElementById("filterPopoutWrap");
const toast              = document.getElementById("toast");
const colorPickerOverlay = document.getElementById("colorPickerOverlay");
const colorSwatches      = document.getElementById("colorSwatches");
const colorPreviewDot    = document.getElementById("colorPreviewDot");
const hexInput           = document.getElementById("hexInput");
const colorCancelBtn     = document.getElementById("colorCancelBtn");
const colorPlaceBtn      = document.getElementById("colorPlaceBtn");

// ── Entry point ───────────────────────────────────────────
entrypoints.setup({
  panels: {
    mockupPanel: {
      show() { init(); }
    }
  }
});

async function init() {
  loadPrefs();
  loadFavorites();
  await new Promise(resolve => setTimeout(resolve, 80));
  // Restore saved folder from persistent token
  const token = localStorage.getItem("mockvault_folder_token");
  if (token) {
    try {
      selectedFolder = await fs.getEntryForPersistentToken(token);
    } catch {
      selectedFolder = null;
      localStorage.removeItem("mockvault_folder_token");
    }
  }
  await loadMockups();
  bindEvents();
  applyPrefs();
  hidePluginLoader();
}

function applyPrefs() {
  // Sync view toggle buttons to loaded prefs
  gridViewBtn.classList.toggle("active", !isListView);
  listViewBtn.classList.toggle("active", isListView);
  mockupGrid.classList.toggle("list-mode", isListView);
  // Sync color filter buttons
  colorableBtn.classList.toggle("active", activeColorFilter === "colorable");
  blackBtn.classList.toggle("active", activeColorFilter === "black");
  whiteBtn.classList.toggle("active", activeColorFilter === "white");
  updateFilterToggleBtn();
}

function updateFilterToggleBtn() {
  filterToggleBtn.classList.toggle("has-filter", activeColorFilter !== null);
}

function hidePluginLoader() {
  const loader = document.getElementById("pluginLoader");
  if (!loader) return;
  document.getElementById("app").classList.remove("loading");
  loader.classList.add("hidden");
  setTimeout(() => loader.remove(), 450);
}

// ── Bind UI events ────────────────────────────────────────
function bindEvents() {
  refreshBtn.addEventListener("click", () => loadMockups());
  folderBtn.addEventListener("click", selectMockupsFolder);

  searchInput.addEventListener("input", () => {
    searchQuery = searchInput.value.trim().toLowerCase();
    clearSearch.style.display = searchQuery ? "flex" : "none";
    renderGrid();
  });

  clearSearch.addEventListener("click", () => {
    searchInput.value = "";
    searchQuery = "";
    clearSearch.style.display = "none";
    renderGrid();
  });

  gridViewBtn.addEventListener("click", () => setView(false));
  listViewBtn.addEventListener("click", () => setView(true));

  // Filter popout toggle
  filterToggleBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    filterPopout.classList.toggle("open");
  });

  document.addEventListener("click", (e) => {
    if (!filterPopoutWrap.contains(e.target)) {
      filterPopout.classList.remove("open");
    }
  });

  [colorableBtn, blackBtn, whiteBtn].forEach(btn => {
    btn.addEventListener("click", () => {
      const filter = btn.dataset.filter;
      activeColorFilter = activeColorFilter === filter ? null : filter;
      colorableBtn.classList.toggle("active", activeColorFilter === "colorable");
      blackBtn.classList.toggle("active", activeColorFilter === "black");
      whiteBtn.classList.toggle("active", activeColorFilter === "white");
      updateFilterToggleBtn();
      filterPopout.classList.remove("open");
      savePrefs();
      renderGrid();
    });
  });

  // Color picker
  colorCancelBtn.addEventListener("click", hideColorPicker);
  colorPickerOverlay.addEventListener("click", (e) => {
    if (e.target === colorPickerOverlay) hideColorPicker();
  });
  colorPlaceBtn.addEventListener("click", () => {
    const target = colorPickerTarget;
    garmentColor = hexInput.value || garmentColor;
    savePrefs();
    hideColorPicker();
    placeMockup(target, garmentColor);
  });
  hexInput.addEventListener("input", () => {
    const val = hexInput.value;
    if (/^#[0-9a-fA-F]{6}$/.test(val)) {
      colorPreviewDot.style.background = val;
      colorSwatches.querySelectorAll(".color-swatch").forEach(s => {
        s.classList.toggle("selected", s.dataset.color.toLowerCase() === val.toLowerCase());
      });
    }
  });

  clearFiltersBtn.addEventListener("click", () => {
    activeCategory = "all";
    activeColorFilter = null;
    searchQuery = "";
    searchInput.value = "";
    clearSearch.style.display = "none";
    colorableBtn.classList.remove("active");
    blackBtn.classList.remove("active");
    whiteBtn.classList.remove("active");
    updateFilterToggleBtn();
    categoryTabs.querySelectorAll(".category-btn").forEach(b => {
      b.classList.toggle("active", b.dataset.category === "all");
    });
    savePrefs();
    renderGrid();
  });
}

function setView(list) {
  isListView = list;
  gridViewBtn.classList.toggle("active", !list);
  listViewBtn.classList.toggle("active", list);
  mockupGrid.classList.toggle("list-mode", list);
  savePrefs();
  renderGrid();
}

// ── Select mockups folder ─────────────────────────────────
async function selectMockupsFolder() {
  try {
    const folder = await fs.getFolder();
    if (!folder) return;
    const token = fs.createPersistentToken(folder);
    localStorage.setItem("mockvault_folder_token", token);
    selectedFolder = folder;
    await loadMockups();
  } catch (err) {
    showToast("Could not open folder", "error");
  }
}

function showNoFolderState() {
  allMockups = [];
  renderCategories();
  mockupGrid.innerHTML = "";
  mockupCount.textContent = "0 mockups";
  clearFiltersBtn.style.display = "none";
  refreshBtn.classList.remove("spinning");
  emptyState.style.display = "flex";
  emptyState.innerHTML = `
    <div class="empty-icon">
      <svg viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M8 20a4 4 0 0 1 4-4h12l4 6h24a4 4 0 0 1 4 4v20a4 4 0 0 1-4 4H12a4 4 0 0 1-4-4V20z" stroke="currentColor" stroke-width="2"/>
      </svg>
    </div>
    <p class="empty-title">No folder selected</p>
    <p class="empty-subtitle">Point MockVault to the folder<br/>where your mockups are saved</p>
    <button class="select-folder-btn" id="selectFolderInline">Select Folder</button>`;
  document.getElementById("selectFolderInline").addEventListener("click", selectMockupsFolder);
}

// ── Load mockups from selected folder ────────────────────
async function loadMockups() {
  refreshBtn.classList.add("spinning");
  mockupGrid.innerHTML = "";
  emptyState.style.display = "none";

  // Show loading skeleton
  showLoading();

  if (!selectedFolder) {
    showNoFolderState();
    return;
  }

  try {
    const entries = await selectedFolder.getEntries();
    const imageExts = ["jpg", "jpeg", "png", "webp", "gif", "svg", "psd", "psb"];

    allMockups = [];

    for (const entry of entries) {
      if (entry.isFolder) {
        // Subfolder = category
        const categoryName = entry.name;
        try {
          const subEntries = await entry.getEntries();
          for (const subEntry of subEntries) {
            const ext = getExt(subEntry.name);
            if (!subEntry.isFolder && imageExts.includes(ext)) {
              const url = await getFileUrl(subEntry);
              const ct = getColorType(subEntry.name);
              allMockups.push({
                name: stripExt(subEntry.name),
                category: categoryName.toLowerCase(),
                colorType: ct,
                colorable: ct === "colorable",
                file: subEntry,
                thumbUrl: url
              });
            }
          }
        } catch { /* skip unreadable subfolder */ }
      } else {
        // Root-level file = "General" category
        const ext = getExt(entry.name);
        if (imageExts.includes(ext)) {
          const url = await getFileUrl(entry);
          const ct = getColorType(entry.name);
          allMockups.push({
            name: stripExt(entry.name),
            category: "general",
            colorType: ct,
            colorable: ct === "colorable",
            file: entry,
            thumbUrl: url
          });
        }
      }
    }

    renderCategories();
    renderGrid();

  } catch (err) {
    showToast("Error loading mockups: " + err.message, "error");
    console.error(err);
  }

  refreshBtn.classList.remove("spinning");
}

async function getFileUrl(fileEntry) {
  try {
    console.log("[MockupHub] Reading file:", fileEntry.name);
    const { formats } = uxp.storage;
    const data = await fileEntry.read({ format: formats.binary });
    console.log("[MockupHub] Read OK:", fileEntry.name, "bytes:", data.byteLength ?? data.length ?? typeof data);

    const ext  = getExt(fileEntry.name);
    const mime = { jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png",
                   webp: "image/webp", gif: "image/gif", svg: "image/svg+xml" }[ext] || "image/png";

    const uint8  = new Uint8Array(data);
    const chunk  = 8192;
    let binary   = "";
    for (let i = 0; i < uint8.length; i += chunk) {
      binary += String.fromCharCode(...uint8.subarray(i, i + chunk));
    }
    const dataUrl = `data:${mime};base64,${btoa(binary)}`;
    console.log("[MockupHub] dataUrl length:", dataUrl.length, "prefix:", dataUrl.substring(0, 30));
    return dataUrl;
  } catch (err) {
    console.error("[MockupHub] getFileUrl error:", fileEntry.name, err);
    return null;
  }
}

// ── Render Categories ─────────────────────────────────────
function renderCategories() {
  const cats = ["all", ...new Set(allMockups.map(m => m.category))].filter(Boolean);
  if (favorites.size > 0) cats.splice(1, 0, "favorites");

  categoryTabs.innerHTML = cats.map(cat => {
    const label = cat === "all" ? "All" : cat === "favorites" ? "★ Saved" : formatName(cat);
    return `<button class="category-btn${cat === activeCategory ? " active" : ""}" data-category="${cat}">${label}</button>`;
  }).join("");

  categoryTabs.querySelectorAll(".category-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      activeCategory = btn.dataset.category;
      categoryTabs.querySelectorAll(".category-btn").forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      renderGrid();
    });
  });

  updateCategoryScroll();
  categoryTabs.addEventListener("scroll", updateCategoryScroll, { passive: true });
}

function updateCategoryScroll() {
  const el = categoryTabs;
  const wrapper = document.querySelector(".categories-wrapper");
  const atStart = el.scrollLeft <= 2;
  const atEnd = el.scrollLeft + el.clientWidth >= el.scrollWidth - 2;
  const hasOverflow = el.scrollWidth > el.clientWidth;
  wrapper.classList.toggle("scroll-left",  hasOverflow && !atStart);
  wrapper.classList.toggle("scroll-right", hasOverflow && !atEnd);
}

// ── Render Grid ───────────────────────────────────────────
function renderGrid() {
  let list = allMockups;

  if (activeCategory === "favorites") {
    list = list.filter(m => favorites.has(favKey(m)));
  } else if (activeCategory !== "all") {
    list = list.filter(m => m.category === activeCategory);
  }
  if (searchQuery) {
    list = list.filter(m =>
      m.name.toLowerCase().includes(searchQuery) ||
      m.category.toLowerCase().includes(searchQuery)
    );
  }
  if (activeColorFilter) {
    list = list.filter(m => m.colorType === activeColorFilter);
  }

  filteredList = list;
  mockupCount.textContent = `${list.length} mockup${list.length !== 1 ? "s" : ""}`;

  const hasFilters = activeCategory !== "all" || activeColorFilter !== null || searchQuery !== "";
  clearFiltersBtn.style.display = hasFilters ? "inline-flex" : "none";

  if (list.length === 0) {
    mockupGrid.innerHTML = "";
    emptyState.style.display = "flex";
    return;
  }

  emptyState.style.display = "none";
  mockupGrid.classList.toggle("list-mode", isListView);

  mockupGrid.innerHTML = list.map((m, i) => buildCard(m, i)).join("");

  // Set img src via JS (UXP blocks inline event handlers)
  mockupGrid.querySelectorAll(".mockup-card").forEach((card) => {
    const idx = parseInt(card.dataset.index);
    const mockup = filteredList[idx];
    const img = card.querySelector(".card-thumb");
    if (img && mockup.thumbUrl) {
      img.addEventListener("load",  () => img.classList.add("loaded"));
      img.addEventListener("error", () => { img.classList.add("img-error"); img.classList.add("loaded"); });
      img.src = mockup.thumbUrl;
    }
  });

  // Favorite buttons
  mockupGrid.querySelectorAll(".fav-btn").forEach(btn => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const idx = parseInt(btn.closest(".mockup-card").dataset.index);
      toggleFavorite(filteredList[idx]);
    });
  });

  // Place buttons
  mockupGrid.querySelectorAll(".place-btn, .place-btn-list").forEach(btn => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const idx = parseInt(btn.closest(".mockup-card").dataset.index);
      handlePlace(filteredList[idx]);
    });
  });

  // Single click in grid = place; double-click in list = place
  mockupGrid.querySelectorAll(".mockup-card").forEach(card => {
    if (!isListView) {
      card.addEventListener("click", () => {
        const idx = parseInt(card.dataset.index);
        handlePlace(filteredList[idx]);
      });
    } else {
      card.addEventListener("dblclick", () => {
        const idx = parseInt(card.dataset.index);
        handlePlace(filteredList[idx]);
      });
    }
  });
}

function buildCard(mockup, index) {
  const badge = mockup.colorable ? `<span class="colorable-badge" title="Colorable mockup"><svg viewBox="0 0 14 14" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="7" cy="7.5" r="5.5" stroke="currentColor" stroke-width="1.2"/><circle cx="4.5" cy="6" r="1" fill="currentColor"/><circle cx="7" cy="4" r="1" fill="currentColor"/><circle cx="9.5" cy="6" r="1" fill="currentColor"/><circle cx="9.2" cy="8.8" r="1.4" fill="currentColor"/></svg></span>` : "";
  const isFav = favorites.has(favKey(mockup));
  const favClass = isFav ? " active" : "";
  const favTitle = isFav ? "Remove from saved" : "Save mockup";
  const star = isFav ? "★" : "☆";

  const displayName = formatName(mockup.name);

  if (isListView) {
    return `
      <div class="mockup-card" data-index="${index}">
        <div class="card-thumb-wrap">
          <img class="card-thumb" alt="${displayName}" />
        </div>
        <div class="card-info">
          <div class="card-name-row">
            <div class="card-name">${displayName}</div>
            ${badge}
          </div>
          <div class="card-category">${cap(mockup.category)}</div>
        </div>
        <div class="card-actions">
          <button class="fav-btn${favClass}" title="${favTitle}">${star}</button>
          <button class="place-btn-list" title="Place mockup">+</button>
        </div>
      </div>`;
  }

  return `
    <div class="mockup-card" data-index="${index}">
      <div class="card-thumb-wrap">
        <img class="card-thumb" alt="${displayName}" />
        <button class="fav-btn${favClass}" title="${favTitle}">${star}</button>
        <div class="card-name-bar">
          <div class="card-name">${displayName}</div>
          ${badge}
        </div>
        <div class="card-overlay">
          <button class="place-btn">+ Place</button>
        </div>
      </div>
    </div>`;
}

// ── Color Picker ──────────────────────────────────────────
function handlePlace(mockup) {
  if (mockup.colorable) {
    showColorPicker(mockup);
  } else {
    placeMockup(mockup);
  }
}

function showColorPicker(mockup) {
  colorPickerTarget = mockup;

  // Build swatches
  colorSwatches.innerHTML = GARMENT_COLORS.map(hex =>
    `<div class="color-swatch${hex.toLowerCase() === garmentColor.toLowerCase() ? " selected" : ""}"
      data-color="${hex}" style="background:${hex}" title="${hex}"></div>`
  ).join("");

  colorSwatches.querySelectorAll(".color-swatch").forEach(swatch => {
    swatch.addEventListener("click", () => {
      const hex = swatch.dataset.color;
      hexInput.value = hex;
      colorPreviewDot.style.background = hex;
      colorSwatches.querySelectorAll(".color-swatch").forEach(s => s.classList.remove("selected"));
      swatch.classList.add("selected");
    });
  });

  hexInput.value = garmentColor;
  colorPreviewDot.style.background = garmentColor;
  colorPickerOverlay.classList.add("show");
}

function hideColorPicker() {
  colorPickerOverlay.classList.remove("show");
  colorPickerTarget = null;
}

// ── Place Mockup into Photoshop ───────────────────────────
async function placeMockup(mockup, color) {
  if (!mockup) return;

  const overlay = showPlacingOverlay();

  try {
    const doc = app.activeDocument;
    if (!doc) throw new Error("No active document open.");

    // UXP requires a session token — raw nativePath doesn't work in batchPlay
    const token = uxp.storage.localFileSystem.createSessionToken(mockup.file);

    await core.executeAsModal(async () => {

      // 1 ── Place as embedded smart object
      await action.batchPlay([{
        _obj: "placeEvent",
        null: { _path: token, _kind: "local" },
        freeTransformCenterState: { _enum: "quadCenterState", _value: "QCSAverage" },
        offset: {
          _obj: "offset",
          horizontal: { _unit: "pixelsUnit", _value: 0 },
          vertical:   { _unit: "pixelsUnit", _value: 0 }
        }
      }], {});

      // 2 ── Center to canvas
      await action.batchPlay([{
        _obj: "align",
        _target: [{ _ref: "layer", _enum: "ordinal", _value: "targetEnum" }],
        using: { _enum: "alignDistributeSelector", _value: "ADSHorizontalCenter" },
        alignToCanvas: true
      }], {});

      await action.batchPlay([{
        _obj: "align",
        _target: [{ _ref: "layer", _enum: "ordinal", _value: "targetEnum" }],
        using: { _enum: "alignDistributeSelector", _value: "ADSVerticalCenter" },
        alignToCanvas: true
      }], {});

      // 3 ── Rename the placed layer
      await action.batchPlay([{
        _obj: "set",
        _target: [{ _ref: "layer", _enum: "ordinal", _value: "targetEnum" }],
        to: { _obj: "layer", name: mockup.name }
      }], {});

      // 4 ── If colorable: add clipped Solid Color layer set to Overlay
      if (mockup.colorable) {
        const rgb = hexToRgb(color || garmentColor);
        await action.batchPlay([{
          _obj: "make",
          _target: [{ _ref: "contentLayer" }],
          using: {
            _obj: "contentLayer",
            name: "Garment Color",
            type: {
              _obj: "solidColorLayer",
              color: { _obj: "RGBColor", red: rgb.r, green: rgb.g, blue: rgb.b }
            }
          }
        }], {});

        await action.batchPlay([{
          _obj: "set",
          _target: [{ _ref: "layer", _enum: "ordinal", _value: "targetEnum" }],
          to: { _obj: "layer", mode: { _enum: "blendMode", _value: "overlay" } }
        }], {});

        await action.batchPlay([{
          _obj: "groupEvent",
          _target: [{ _ref: "layer", _enum: "ordinal", _value: "targetEnum" }]
        }], {});
      }

    }, { commandName: "Place Mockup" });

    hidePlacingOverlay(overlay);
    const msg = mockup.colorable
      ? `"${mockup.name}" placed — double-click "Garment Color" to recolor`
      : `"${mockup.name}" placed & centered`;
    showToast(msg, "success");

  } catch (err) {
    hidePlacingOverlay(overlay);
    console.error("[Place] FINAL error:", err.message, err);
    showToast(err.message || "Failed to place mockup", "error");
  }
}

// ── Helpers ───────────────────────────────────────────────
function showLoading() {
  mockupGrid.innerHTML = `
    <div class="loading-state loading-full">
      <div class="spinner"></div>
      <p class="loading-text">Loading mockups…</p>
    </div>`;
  emptyState.style.display = "none";
}

function showPlacingOverlay() {
  const el = document.createElement("div");
  el.className = "placing-overlay";
  el.innerHTML = `
    <div class="spinner"></div>
    <p>Placing mockup…</p>`;
  document.body.appendChild(el);
  requestAnimationFrame(() => el.classList.add("show"));
  return el;
}

function hidePlacingOverlay(el) {
  if (!el) return;
  el.classList.remove("show");
  setTimeout(() => el.remove(), 300);
}

let toastTimer;
function showToast(msg, type = "") {
  clearTimeout(toastTimer);
  toast.textContent = msg;
  toast.className = "toast" + (type ? ` ${type}` : "") + " show";
  toastTimer = setTimeout(() => toast.classList.remove("show"), 3000);
}

function getExt(filename) {
  return filename.split(".").pop().toLowerCase();
}

function stripExt(filename) {
  return filename.replace(/\.[^.]+$/, "");
}

function cap(str) {
  if (!str) return "";
  return str.charAt(0).toUpperCase() + str.slice(1);
}

function hexToRgb(hex) {
  const h = hex.replace("#", "");
  return {
    r: parseInt(h.slice(0, 2), 16),
    g: parseInt(h.slice(2, 4), 16),
    b: parseInt(h.slice(4, 6), 16)
  };
}

function formatName(name) {
  return name.replace(/[_-]+/g, " ").replace(/\b\w/g, c => c.toUpperCase());
}

function getColorType(filename) {
  if (/(_colorable|_color|_grey|_gray)/i.test(filename)) return "colorable";
  if (/(_black|_blk)/i.test(filename)) return "black";
  if (/(_white|_wht)/i.test(filename)) return "white";
  return null;
}
