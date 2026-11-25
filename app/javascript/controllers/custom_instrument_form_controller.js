import { Controller } from "@hotwired/stimulus";

const PREVIEW_DEBOUNCE_MS = 400;

// The custom instrument form: template quick-fill, caret insertion for the
// asset chips and the stock combobox, the debounced live preview, and the
// edit-only "history will be recalculated" warning.
export default class extends Controller {
  static targets = [
    "name",
    "symbol",
    "formula",
    "currency",
    "preview",
    "historyWarning",
  ];

  static values = {
    templates: Array,
    previewUrl: String,
    instrumentId: String,
    errorText: String,
  };

  static classes = ["busy"];

  connect() {
    this.previewTimer = null;
    this.previewAbort = null;
    this.initializeTemplateMarkers();
    this.refreshHistoryWarning();

    if (this.formulaTarget.value.trim() !== "") this.schedulePreview();
  }

  disconnect() {
    clearTimeout(this.previewTimer);
    this.previewAbort?.abort();
    this.previewAbort = null;
  }

  applyTemplate(event) {
    const template = this.templatesValue.find(
      (candidate) => candidate.key === event.currentTarget.value,
    );
    if (!template) return;

    this.fillFromTemplate(this.nameTarget, template.name);
    this.fillFromTemplate(this.symbolTarget, template.symbol);
    this.fillFromTemplate(this.formulaTarget, template.formula);
    this.schedulePreview();
  }

  // A template chosen through ?template= arrives already filled by the
  // server, so its fields carry no marker yet. Marking values that match the
  // selected template lets switching to another one replace them.
  initializeTemplateMarkers() {
    const select = this.element.querySelector("select[name='template']");
    if (!select?.value) return;

    const template = this.templatesValue.find(
      (candidate) => candidate.key === select.value,
    );
    if (!template) return;

    this.markIfMatching(this.nameTarget, template.name);
    this.markIfMatching(this.symbolTarget, template.symbol);
    this.markIfMatching(this.formulaTarget, template.formula);
  }

  markIfMatching(field, value) {
    if (field.value === value) {
      field.dataset.customInstrumentFormTemplateValue = value;
    }
  }

  // Only a field the user has not typed into is filled. The last template's
  // value stays on the field, so switching templates keeps replacing a value
  // that still came from one, and leaves a hand-written value alone.
  fillFromTemplate(field, value) {
    const previousTemplateValue =
      field.dataset.customInstrumentFormTemplateValue;

    if (field.value.trim() === "" || field.value === previousTemplateValue) {
      field.value = value;
    }
    field.dataset.customInstrumentFormTemplateValue = value;
  }

  insertToken(event) {
    this.insertAtCaret(event.currentTarget.dataset.customInstrumentFormToken);
  }

  insertSecurity(event) {
    const value = event.detail?.value;
    if (!value) return;

    const [ticker, mic] = value.split("|");
    if (!ticker) return;

    this.insertAtCaret(mic ? `[${ticker}:${mic}]` : `[${ticker}]`);
    this.clearSecurityLookup();
  }

  insertAtCaret(text) {
    if (!text) return;

    const field = this.formulaTarget;
    const start = field.selectionStart ?? field.value.length;
    const end = field.selectionEnd ?? field.value.length;
    const before = field.value.slice(0, start);
    const after = field.value.slice(end);
    const needsSpaceBefore =
      before.length > 0 && !/[\s(+\-*/×÷·]$/.test(before);
    const needsSpaceAfter = after.length > 0 && !/^[\s)+\-*/×÷·]/.test(after);
    const inserted = `${needsSpaceBefore ? " " : ""}${text}${
      needsSpaceAfter ? " " : ""
    }`;

    field.value = `${before}${inserted}${after}`;

    const caret = before.length + inserted.length;
    field.focus();
    field.setSelectionRange(caret, caret);
    field.dispatchEvent(new Event("input", { bubbles: true }));
  }

  schedulePreview() {
    clearTimeout(this.previewTimer);
    this.refreshHistoryWarning();

    if (this.formulaTarget.value.trim() === "") {
      this.clearPreview();
      return;
    }

    this.previewTimer = setTimeout(
      () => this.requestPreview(),
      PREVIEW_DEBOUNCE_MS,
    );
  }

  async requestPreview() {
    this.previewAbort?.abort();

    const controller = new AbortController();
    this.previewAbort = controller;
    this.setBusy(true);

    try {
      const response = await fetch(this.previewUrlValue, {
        method: "POST",
        headers: {
          Accept: "text/html",
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": this.csrfToken,
        },
        body: new URLSearchParams({
          formula: this.formulaTarget.value,
          currency: this.currencyTarget.value,
          symbol: this.symbolTarget.value,
          id: this.instrumentIdValue || "",
        }),
        signal: controller.signal,
      });

      if (!response.ok) throw new Error(`Preview failed: ${response.status}`);

      const html = await response.text();
      if (controller.signal.aborted) return;

      this.previewTarget.innerHTML = html;
      this.updateFormulaValidity();
    } catch (error) {
      if (error.name === "AbortError") return;

      this.previewTarget.innerHTML = `<div data-custom-instrument-preview-state="error"><p class="text-xs text-destructive" role="alert">${this.escape(this.errorTextValue)}</p></div>`;
      this.setFormulaValidity(true);
    } finally {
      if (!controller.signal.aborted) this.setBusy(false);
    }
  }

  clearPreview() {
    this.previewAbort?.abort();
    this.previewAbort = null;
    this.previewTarget.innerHTML = "";
    this.setBusy(false);
    this.setFormulaValidity(false);
  }

  updateFormulaValidity() {
    const state = this.previewTarget.querySelector(
      "[data-custom-instrument-preview-state]",
    )?.dataset.customInstrumentPreviewState;

    this.setFormulaValidity(state === "error");
  }

  // The preview is the only place a formula error is explained, so a failed
  // formula points the field at it for AT users until a later answer is ok.
  setFormulaValidity(invalid) {
    if (invalid) {
      this.formulaTarget.setAttribute("aria-invalid", "true");
      if (this.previewTarget.id) {
        this.formulaTarget.setAttribute(
          "aria-describedby",
          this.previewTarget.id,
        );
      }
    } else {
      this.formulaTarget.removeAttribute("aria-invalid");
      this.formulaTarget.removeAttribute("aria-describedby");
    }
  }

  refreshHistoryWarning() {
    if (!this.hasHistoryWarningTarget) return;

    const warning = this.historyWarningTarget;
    const savedFormula = (
      warning.dataset.customInstrumentFormSavedFormulaValue || ""
    ).trim();
    const formulaChanged = this.formulaTarget.value.trim() !== savedFormula;
    const currencyChanged =
      this.currencyTarget.value !==
      warning.dataset.customInstrumentFormSavedCurrencyValue;

    warning.classList.toggle("hidden", !(formulaChanged || currencyChanged));
  }

  setBusy(busy) {
    this.previewTarget.setAttribute("aria-busy", busy ? "true" : "false");
    if (this.hasBusyClass) {
      this.previewTarget.classList.toggle(this.busyClass, busy);
    }
  }

  clearSecurityLookup() {
    const element = this.element.querySelector(
      '[data-controller~="hw-combobox"]',
    );
    if (!element) return;

    const controller = this.application.getControllerForElementAndIdentifier(
      element,
      "hw-combobox",
    );
    controller?.clear();
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content ?? "";
  }

  escape(value) {
    const element = document.createElement("div");
    element.textContent = value;
    return element.innerHTML;
  }
}
