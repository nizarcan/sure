import { Controller } from "@hotwired/stimulus";

// The investment account form's currency picker can name a custom instrument.
// Choosing one turns the balance field into a quantity of that instrument and
// reveals its optional price paid per unit; any other currency restores money.
export default class extends Controller {
  static targets = [
    "currency",
    "amount",
    "amountLabel",
    "amountSymbol",
    "operatorRow",
    "priceField",
  ];

  change(event) {
    if (event.target !== this.currencyTarget) return;

    this.apply();
  }

  apply() {
    const instrument = this.#selectedInstrument();
    if (!instrument) {
      this.amountLabelTarget.textContent =
        this.amountLabelTarget.dataset.moneyLabel;
      this.priceFieldTarget.classList.add("hidden");
      if (this.hasOperatorRowTarget) this.operatorRowTarget.style.display = "";
      return;
    }

    this.amountLabelTarget.textContent =
      this.amountLabelTarget.dataset.quantityLabel;
    this.amountSymbolTarget.textContent = instrument.symbol;
    // Units are not money: no rounding to the currency's precision, and the
    // arithmetic operator row does not apply.
    this.amountTarget.step = "any";
    if (this.hasOperatorRowTarget) this.operatorRowTarget.style.display = "none";
    this.#showPriceField(instrument);
  }

  #selectedInstrument() {
    const option = this.currencyTarget.selectedOptions[0];
    if (!option || !option.value.startsWith("instrument:")) return null;

    return {
      symbol: option.dataset.instrumentSymbol || "",
      currencySymbol: option.dataset.instrumentCurrencySymbol || "",
    };
  }

  #showPriceField(instrument) {
    if (!this.hasPriceFieldTarget) return;

    this.priceFieldTarget.classList.remove("hidden");
    const symbol = this.priceFieldTarget.querySelector(
      '[data-money-field-target="symbol"]',
    );
    if (symbol) symbol.textContent = instrument.currencySymbol;
  }
}
