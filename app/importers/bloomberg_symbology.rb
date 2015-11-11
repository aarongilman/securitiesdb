require 'date'
require 'pp'

require_relative "../clients/bsym"

class BloombergSymbologyImporter
  attr_accessor :bsym_client

  def initialize
    self.bsym_client = Bsym::Client.new

    @exchange_memo = {}
    @security_type_memo = {}
  end

  def log(msg)
    Application.logger.info(msg)
  end

  def import(exchanges_to_import = Exchange.us_exchanges)
    import_exchanges(bsym_client.pricing_sources)

    exchange_labels = exchanges_to_import.map(&:label)
    selection_predicate = ->(bsym_security) { exchange_labels.include?(bsym_security.pricing_source) }

    import_securities(bsym_client.stocks.select(&selection_predicate), "Stock")
    import_securities(bsym_client.etps.select(&selection_predicate), "ETP")
    import_securities(bsym_client.funds.select(&selection_predicate), "Fund")
    import_securities(bsym_client.indices.select(&selection_predicate), "Index")

    # import_custom_securities
  end

  def import_exchanges(pricing_sources)
    log "Importing Bloomberg pricing sources as exchanges."
    pricing_sources.each {|pricing_source| create_or_update_exchange(pricing_source.description, pricing_source.label) }

    # log "Creating user-defined exchanges"
    # create_or_update_exchange("DKE", "DKE")
  end

  def create_or_update_exchange(name, label)
    existing_exchange = Exchange.first(label: label)
    begin
      if existing_exchange
        existing_exchange.update(name: name, label: label)
      else
        Exchange.create(name: name, label: label)
      end
    rescue => e
      log "Can't import exchange (name=#{name} label=#{label}): #{e.message}"
    end
  end

  def import_securities(bsym_securities, asset_class_category)
    log "Importing Bloomberg symbols for asset class category #{asset_class_category}."
    bsym_securities.each {|bsym_security| import_security(bsym_security) }
  end

  def import_security(bsym_security)
    create_or_update_security(bsym_security)
  end

  def lookup_exchange(label)
    @exchange_memo[label] ||= Exchange.first(label: label)
  end

  def lookup_security_type(market_sector, security_type)
    @security_type_memo[label] ||= SecurityType.first(market_sector: market_sector, name: security_type)
  end

  # def import_custom_securities
  #   log "Importing user-defined securities."
  #   create_or_update_security("CBOE", "BBGDKE1", "BBGDKE1", "CBOE 1 Month SPX Volatility Index", "^VIX")
  #   create_or_update_security("CBOE", "BBGDKE2", "BBGDKE2", "CBOE 3 Month SPX Volatility Index", "^VXV")
  # end

  # Bsym::Security is defined as Security = Struct.new(:name, :ticker, :pricing_source, :bsid, :unique_id, :security_type, :market_sector, :figi, :composite_bbgid)
  def create_or_update_security(bsym_security)
    exchange = lookup_exchange(bsym_security.pricing_source)
    security_type = lookup_security_type(bsym_security.market_sector, bsym_security.security_type)
    if exchange && security_type
      existing_security = Security.first(figi: bsym_security.figi)
      if existing_security
        replacement_attributes = {}
        replacement_attributes[:exchange] = exchange if existing_security.exchange &&
                                                        existing_security.exchange.label != bsym_security.pricing_source
        replacement_attributes[:security_type] = security_type if existing_security.security_type &&
                                                                  existing_security.security_type.market_sector != bsym_security.market_sector &&
                                                                  existing_security.security_type.name != bsym_security.security_type
        replacement_attributes[:name] = bsym_security.name if existing_security.name != bsym_security.name
        replacement_attributes[:symbol] = bsym_security.ticker if existing_security.symbol != bsym_security.ticker
        replacement_attributes[:bbgcid] = bsym_security.composite_bbgid if existing_security.bbgcid != bsym_security.composite_bbgid

        existing_security.update(replacement_attributes)
      else
        Security.create(
          figi: figi,
          bb_gcid: bb_gcid,
          name: name,
          symbol: symbol,
          exchange: exchange ? exchange : []
        )
      end
    else
      log "Unknown exchange, #{bsym_security.pricing_source.inspect}, or unknown security type, (#{bsym_security.market_sector.inspect}, #{bsym_security.security_type.inspect}). Security defined as #{bsym_security.inspect}"
    end
  rescue Sequel::ValidationFailed, Sequel::HookFailed => e
    log "Can't import #{bsym_security.inspect}: #{e.message}"
  rescue => e
    log "Can't import #{bsym_security.inspect}: #{e.message}"
    log e.backtrace.join("\n")
  end
end
