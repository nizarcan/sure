require "test_helper"

class CustomInstrumentPriceJobTest < ActiveJob::TestCase
  include CustomInstrumentTestHelper
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:investment)
  end

  test "imports the earliest trade window, syncs its accounts, enqueues dependents and refreshes" do
    instrument = create_custom_instrument(family: @family, symbol: "JOBROOT", formula: "XAU")
    dependent = create_custom_instrument(family: @family, symbol: "JOBDEP", formula: "1 * JOBROOT")
    trade_date = 2.years.ago.to_date
    create_trade(instrument.security, account: @account, qty: 1, date: trade_date, price: 10)

    instrument.expects(:import_prices).with(start_date: trade_date, end_date: Date.current).once
    Account.any_instance.expects(:sync_later).once
    Family.any_instance.expects(:broadcast_refresh).once

    assert_enqueued_with(job: CustomInstrumentPriceJob, args: [ dependent ]) do
      CustomInstrumentPriceJob.perform_now(instrument)
    end
  end

  test "uses a one year window when the instrument has no trades" do
    instrument = create_custom_instrument(family: @family, symbol: "JOBHOLD", formula: "XAU")
    @account.holdings.create!(security: instrument.security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    instrument.expects(:import_prices).with(start_date: 1.year.ago.to_date, end_date: Date.current).once
    Account.any_instance.expects(:sync_later).once
    Family.any_instance.expects(:broadcast_refresh).once

    CustomInstrumentPriceJob.perform_now(instrument)
  end

  test "does nothing for a missing instrument" do
    assert_nothing_raised { CustomInstrumentPriceJob.perform_now(nil) }
  end

  test "discards deserialization errors" do
    assert_includes CustomInstrumentPriceJob.rescue_handlers.map(&:first), "ActiveJob::DeserializationError"
  end
end
