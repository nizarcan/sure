require "test_helper"
require "ostruct"

class CustomInstrument::RateSourceTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    ExchangeRate.delete_all
    ExchangeRatePair.delete_all
    @start_date = 20.days.ago.to_date
    @end_date = Date.current
  end

  test "does nothing for a pair with equal currencies" do
    ExchangeRate.expects(:import_provider_rates).never
    Provider::Frankfurter.any_instance.expects(:fetch_exchange_rates).never

    CustomInstrument::RateSource.import(from: "USD", to: "USD", start_date: @end_date, end_date: @end_date)
  end

  test "delegates a non-metal pair to the ordinary importer" do
    ExchangeRate.expects(:import_provider_rates)
              .with(from: "EUR", to: "GBP", start_date: @end_date, end_date: @end_date, clear_cache: false)
              .once

    CustomInstrument::RateSource.import(from: "EUR", to: "GBP", start_date: @end_date, end_date: @end_date)
  end

  test "delegates a metal pair when Frankfurter is the configured provider" do
    ExchangeRate.stubs(:provider_name).returns("frankfurter")
    ExchangeRate.expects(:import_provider_rates).once
    Provider::Frankfurter.any_instance.expects(:fetch_exchange_rates).never

    CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: @start_date, end_date: @end_date)
  end

  test "falls back to Frankfurter when the configured provider returns nothing" do
    ExchangeRatePair.create!(
      from_currency: "XAU", to_currency: "USD", provider_name: "twelve_data", first_provider_rate_on: 10.years.ago.to_date
    )
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.expects(:import_provider_rates).once
    Provider::Frankfurter.any_instance
                         .stubs(:fetch_exchange_rates)
                         .returns(provider_success_response([
                           OpenStruct.new(from: "XAU", to: "USD", date: @end_date, rate: 3000)
                         ]))

    CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: @end_date, end_date: @end_date)

    assert_equal BigDecimal("3000"), ExchangeRate.find_by(from_currency: "XAU", to_currency: "USD", date: @end_date).rate
    pair = ExchangeRatePair.find_by(from_currency: "XAU", to_currency: "USD")
    assert_equal "frankfurter", pair.provider_name
  end

  test "never asks Frankfurter for a non-metal pair" do
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.stubs(:import_provider_rates)
    Provider::Frankfurter.any_instance.expects(:fetch_exchange_rates).never

    CustomInstrument::RateSource.import(from: "EUR", to: "GBP", start_date: @start_date, end_date: @end_date)
  end

  test "refreshes a four-day-old rate from Frankfurter" do
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.expects(:import_provider_rates).never

    (@start_date..@end_date - 4).each do |date|
      ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: date, rate: 1000)
    end

    Provider::Frankfurter.any_instance
                         .stubs(:fetch_exchange_rates)
                         .returns(provider_success_response(
                           (@start_date..@end_date).map { |date| OpenStruct.new(from: "XAU", to: "USD", date: date, rate: 3000) }
                         ))

    CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: @start_date, end_date: @end_date)

    assert_equal BigDecimal("3000"), ExchangeRate.find_by(
      from_currency: "XAU", to_currency: "USD", date: @end_date - 4
    ).rate
  end

  test "fills holes in the middle of a sparse metal history" do
    start_date = Date.new(2026, 5, 28)
    end_date = Date.new(2026, 11, 7)
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.expects(:import_provider_rates).never

    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: start_date, rate: 1000)
    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: end_date, rate: 2000)

    Provider::Frankfurter.any_instance
                         .stubs(:fetch_exchange_rates)
                         .returns(provider_success_response([
                           OpenStruct.new(from: "XAU", to: "USD", date: start_date, rate: 1000),
                           OpenStruct.new(from: "XAU", to: "USD", date: end_date, rate: 2000)
                         ]))

    CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: start_date, end_date: end_date)

    persisted = ExchangeRate.where(from_currency: "XAU", to_currency: "USD", date: start_date..end_date)
                            .where("rate > 0")
                            .distinct
                            .count(:date)
    assert_equal (start_date..end_date).count, persisted
    assert ExchangeRate.exists?(from_currency: "XAU", to_currency: "USD", date: start_date + 1.day)
  end

  test "corrects the carried-forward tail once an hour and not more often" do
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.expects(:import_provider_rates).never

    (@start_date..@end_date).each do |date|
      ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: date, rate: 1000)
    end

    calls = []
    end_date = @end_date
    provider = Object.new
    provider.define_singleton_method(:fetch_exchange_rates) do |**|
      calls << true
      rate = calls.size == 1 ? 2000 : 2100
      Provider::Response.new(
        success?: true,
        data: [ OpenStruct.new(from: "XAU", to: "USD", date: end_date, rate: rate) ],
        error: nil
      )
    end
    provider.define_singleton_method(:max_history_days) { nil }
    Provider::Frankfurter.stubs(:new).returns(provider)

    CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: @start_date, end_date: @end_date)
    assert_equal BigDecimal("2000"), ExchangeRate.find_by(from_currency: "XAU", to_currency: "USD", date: @end_date).rate

    CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: @start_date, end_date: @end_date)
    assert_equal 1, calls.size

    travel 61.minutes do
      CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: @start_date, end_date: @end_date)
    end

    assert_equal 2, calls.size
    assert_equal BigDecimal("2100"), ExchangeRate.find_by(from_currency: "XAU", to_currency: "USD", date: @end_date).rate
  end

  test "does not call a failing configured provider it has not served the pair before" do
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.expects(:import_provider_rates).never
    Provider::Frankfurter.any_instance.stubs(:fetch_exchange_rates).returns(provider_success_response([]))

    CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: @start_date, end_date: @end_date)
  end

  test "does not refetch before Frankfurter's own first date every run" do
    earliest = @end_date - 10.days
    start_date = earliest - 5.years
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.expects(:import_provider_rates).never
    Rails.cache.write("custom_instrument:frankfurter_first:XAU:USD", earliest, expires_in: 1.week)
    Rails.cache.write("custom_instrument:frankfurter_tail:XAU:USD", true, expires_in: 1.hour)

    (earliest..@end_date).each do |date|
      ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: date, rate: 1000)
    end

    Provider::Frankfurter.any_instance.expects(:fetch_exchange_rates).never

    CustomInstrument::RateSource.import(from: "XAU", to: "USD", start_date: start_date, end_date: @end_date)
  end

  test "current uses a stored rate from the last five days for a non-metal" do
    rate = ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 2.days.ago.to_date, rate: 1.2)
    ExchangeRate.expects(:find_or_fetch_rate).never

    assert_equal({ rate: BigDecimal("1.2"), date: rate.date }, CustomInstrument::RateSource.current(from: "EUR", to: "USD"))
  end

  test "current asks Frankfurter before a non-Frankfurter configured provider for a metal" do
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.expects(:find_or_fetch_rate).never
    Provider::Frankfurter.any_instance
                         .expects(:fetch_exchange_rate)
                         .with(from: "XAU", to: "USD", date: Date.current)
                         .once
                         .returns(provider_success_response(OpenStruct.new(date: Date.current, from: "XAU", to: "USD", rate: 3000.0)))

    assert_equal BigDecimal("3000.0"), CustomInstrument::RateSource.current(from: "XAU", to: "USD")[:rate]
    assert_equal BigDecimal("3000.0"), CustomInstrument::RateSource.current(from: "XAU", to: "USD")[:rate]
  end

  test "current ignores a stale stored metal rate" do
    ExchangeRate.create!(from_currency: "XAU", to_currency: "USD", date: 4.days.ago.to_date, rate: 1000)
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.expects(:find_or_fetch_rate).never
    Provider::Frankfurter.any_instance
                         .expects(:fetch_exchange_rate)
                         .with(from: "XAU", to: "USD", date: Date.current)
                         .returns(provider_success_response(OpenStruct.new(date: Date.current, from: "XAU", to: "USD", rate: 3000.0)))

    assert_equal BigDecimal("3000.0"), CustomInstrument::RateSource.current(from: "XAU", to: "USD")[:rate]
  end

  test "current caches a non-metal provider answer for ten minutes" do
    ExchangeRate.expects(:find_or_fetch_rate)
              .with(from: "EUR", to: "USD", cache: false)
              .once
              .returns(OpenStruct.new(rate: 1.3, date: Date.current))

    assert_equal BigDecimal("1.3"), CustomInstrument::RateSource.current(from: "EUR", to: "USD")[:rate]
    assert_equal BigDecimal("1.3"), CustomInstrument::RateSource.current(from: "EUR", to: "USD")[:rate]
  end

  test "current caches a provider failure for a minute" do
    ExchangeRate.expects(:find_or_fetch_rate)
              .with(from: "EUR", to: "USD", cache: false)
              .once
              .returns(nil)

    assert_nil CustomInstrument::RateSource.current(from: "EUR", to: "USD")
    assert_nil CustomInstrument::RateSource.current(from: "EUR", to: "USD")
  end

  test "current never persists a fetched rate" do
    ExchangeRate.stubs(:find_or_fetch_rate)
              .with(from: "EUR", to: "USD", cache: false)
              .returns(OpenStruct.new(rate: 1.3, date: Date.current))

    assert_no_difference [ "ExchangeRate.count", "ExchangeRatePair.count" ] do
      assert_equal BigDecimal("1.3"), CustomInstrument::RateSource.current(from: "EUR", to: "USD")[:rate]
    end
  end

  test "current falls back to Frankfurter for a metal without persisting" do
    ExchangeRate.stubs(:provider_name).returns("twelve_data")
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    Provider::Frankfurter.any_instance
                         .expects(:fetch_exchange_rate)
                         .with(from: "XAU", to: "USD", date: Date.current)
                         .returns(provider_success_response(OpenStruct.new(date: Date.current, from: "XAU", to: "USD", rate: 3000.0)))

    assert_no_difference [ "ExchangeRate.count", "ExchangeRatePair.count" ] do
      current = CustomInstrument::RateSource.current(from: "XAU", to: "USD")
      assert_equal BigDecimal("3000.0"), current[:rate]
      assert_equal Date.current, current[:date]
    end
  end
end
