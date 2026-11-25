class CustomInstrumentPriceJob < ApplicationJob
  queue_as :default

  # ApplicationJob already discards deserialization errors; repeating it here
  # documents that a deleted instrument is not worth retrying.
  discard_on ActiveJob::DeserializationError

  def perform(instrument)
    return unless instrument&.persisted?

    instrument.import_prices(start_date: window_start(instrument), end_date: Date.current)

    direct_accounts(instrument).find_each(&:sync_later)
    instrument.dependents.find_each { |dependent| self.class.perform_later(dependent) }

    instrument.family.broadcast_refresh
  end

  private
    def window_start(instrument)
      earliest_trade = Trade.joins(:entry).where(security_id: instrument.security_id).minimum("entries.date")
      [ 1.year.ago.to_date, earliest_trade ].compact.min
    end

    def direct_accounts(instrument)
      trade_accounts = Trade.joins(:entry).where(security_id: instrument.security_id).select("entries.account_id")
      holding_accounts = Holding.where(security_id: instrument.security_id).select(:account_id)

      Account.where(id: trade_accounts).or(Account.where(id: holding_accounts))
    end
end
