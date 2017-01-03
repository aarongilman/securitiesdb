require 'date'
require 'io/console'
require 'pp'

require_relative "../clients/csidata"

class CsiDataImporter
  using DateExtensions

  UNKNOWN_INDUSTRY_NAME = "Unknown"
  UNKNOWN_SECTOR_NAME = "Unknown"
  UNKNOWN_SECURITY_TYPE = "Unknown"
  APPROXIMATE_SEARCH_THRESHOLD = 0.7

  # this is a mapping from [CSI Exchange, CSI Child Exchange] to exchange label as defined in ExchangesImporter
  CSI_EXCHANGE_PAIR_TO_EXCHANGE_LABEL_MAP = {
    ["AMEX", nil] => "NYSE-MKT",
    ["AMEX", "AMEX"] => "NYSE-MKT",
    ["AMEX", "BATS Global Markets"] => "BATS-CATCHALL",
    ["AMEX", "NYSE"] => "NYSE",
    ["AMEX", "NYSE ARCA"] => "NYSE-ARCA",
    ["AMEX", "OTC Markets QX"] => "OTC-QX",
    ["AMEX", "OTC Markets QB"] => "OTC-QB",
    ["AMEX", "OTC Markets Pink Sheets"] => "OTC-PINK",
    ["NYSE", nil] => "NYSE",
    ["NYSE", "AMEX"] => "NYSE-MKT",
    ["NYSE", "BATS Global Markets"] => "BATS-CATCHALL",
    ["NYSE", "Nasdaq Capital Market"] => "NASDAQ-CM",
    ["NYSE", "Nasdaq Global Market"] => "NASDAQ-GM",
    ["NYSE", "Nasdaq Global Select"] => "NASDAQ-GSM",
    ["NYSE", "NYSE"] => "NYSE",
    ["NYSE", "NYSE ARCA"] => "NYSE-ARCA",
    ["NYSE", "OTC Markets QB"] => "OTC-QB",
    ["NYSE", "OTC Markets QX"] => "OTC-QX",
    ["NYSE", "OTC Markets Pink Sheets"] => "OTC-PINK",
    ["NASDAQ", nil] => "NASDAQ-CATCHALL",
    ["NASDAQ", "AMEX"] => "NYSE-MKT",
    ["NASDAQ", "BATS Global Markets"] => "BATS-CATCHALL",
    ["NASDAQ", "Grey Market"] => "NASDAQ-CATCHALL",
    ["NASDAQ", "Nasdaq Capital Market"] => "NASDAQ-CM",
    ["NASDAQ", "Nasdaq Global Market"] => "NASDAQ-GM",
    ["NASDAQ", "Nasdaq Global Select"] => "NASDAQ-GSM",
    ["NASDAQ", "NYSE"] => "NYSE",
    ["NASDAQ", "NYSE ARCA"] => "NYSE-ARCA",
    ["NASDAQ", "OTC Markets QB"] => "OTC-QB",
    ["NASDAQ", "OTC Markets QX"] => "OTC-QX",
    ["NASDAQ", "OTC Markets Pink Sheets"] => "OTC-PINK",
    ["OTC", nil] => "OTC",
    ["OTC", "AMEX"] => "NYSE-MKT",
    ["OTC", "BATS Global Markets"] => "BATS-CATCHALL",
    ["OTC", "Nasdaq Capital Market"] => "NASDAQ-CM",
    ["OTC", "Nasdaq Global Market"] => "NASDAQ-GM",
    ["OTC", "Nasdaq Global Select"] => "NASDAQ-GSM",
    ["OTC", "NYSE"] => "NYSE",
    ["OTC", "NYSE ARCA"] => "NYSE-ARCA",
    ["OTC", "OTC Markets QB"] => "OTC-QB",
    ["OTC", "OTC Markets QX"] => "OTC-QX",
    ["OTC", "OTC Markets Pink Sheets"] => "OTC-PINK",
    ["MUTUAL", nil] => "MUTUAL",
    ["MUTUAL", "Mutual Fund"] => "MUTUAL",
    ["INDEX", nil] => "INDEX",
    ["INDEX", "Stock Indices"] => "INDEX",
    ["FINDEX", nil] => "INDEX",
    ["FINDEX", "Foreign Stock Indices"] => "INDEX"
  }

  attr_accessor :csi_client

  EquitySecurityType = "Equity"
  ETFSecurityType = "Exchange Traded Fund"
  ETNSecurityType = "Exchange Traded Note"
  MutualFundSecurityType = "Mutual Fund"
  IndexSecurityType = "Index"

  def initialize
    self.csi_client = CsiData::Client.new
    @exchange_memo = {}
    @similarity_measure = SimString::ComputeSimilarity.new(SimString::NGramBuilder.new(3), SimString::CosineMeasure.new)
  end

  def log(msg)
    Application.logger.info("#{Time.now} - #{msg}")
  end

  def import
    import_amex
    import_nyse
    import_nasdaq
    import_etfs
    import_etns
    import_mutual_funds
    import_us_stock_indices

    SecurityNameDatabaseRegistry.save_all
  end

  def import_amex
    log "*" * 80
    log "Importing CSI Data symbols for AMEX."
    csi_securities = csi_client.amex
    import_securities(csi_securities, EquitySecurityType)
  end

  def import_nyse
    log "*" * 80
    log "Importing CSI Data symbols for NYSE."
    csi_securities = csi_client.nyse
    import_securities(csi_securities, EquitySecurityType)
  end

  def import_nasdaq
    log "*" * 80
    log "Importing CSI Data symbols for Nasdaq + OTC."
    csi_securities = csi_client.nasdaq_otc
    import_securities(csi_securities, EquitySecurityType)
  end

  def import_etfs
    log "*" * 80
    log "Importing CSI Data symbols for ETFs."
    csi_securities = csi_client.etfs
    import_securities(csi_securities, ETFSecurityType)
  end

  def import_etns
    log "*" * 80
    log "Importing CSI Data symbols for ETNs."
    csi_securities = csi_client.etns
    import_securities(csi_securities, ETNSecurityType)
  end

  def import_mutual_funds
    log "*" * 80
    log "Importing CSI Data symbols for Mutual Funds."
    csi_securities = csi_client.mutual_funds
    import_securities(csi_securities, MutualFundSecurityType)
  end

  def import_us_stock_indices
    log "*" * 80
    log "Importing CSI Data symbols for US Stock Indices."
    csi_securities = csi_client.us_stock_indices
    import_securities(csi_securities, IndexSecurityType)
  end

  def import_securities(csi_securities, default_security_type)
    log("Importing #{csi_securities.count} securities from CSI.")
    csi_securities.each do |csi_security|
      import_security(csi_security, default_security_type)
    end
  end

  def lookup_exchange(csi_security)
    csi_exchange_pair = [csi_security.exchange, csi_security.sub_exchange]
    exchange_label = CSI_EXCHANGE_PAIR_TO_EXCHANGE_LABEL_MAP[ csi_exchange_pair ]
    @exchange_memo[exchange_label] ||= Exchange.first(label: exchange_label)
  end

  # active_date is a yyyymmdd integer representation of a date within the active trading window of the security listing on the given exchange
  def import_security(csi_security, default_security_type)
    # 1. lookup exchange
    exchange = lookup_exchange(csi_security)

    active_date = Date.parse(csi_security.start_date).to_datestamp

    if exchange
      # 2. lookup listed securities in <exchange> by given symbol and active date
      listed_securities = ListedSecurity.
                     where(
                       exchange_id: exchange.id,
                       symbol: csi_security.symbol
                     ).
                     where {
                       (listing_start_date <= active_date) &
                       ((listing_end_date >= active_date) | (listing_end_date =~ nil))
                     }.to_a

      case listed_securities.count
      when 0                                  # if no listed securities found, find or create for the underlying security and then create the listed security
        log("Creating #{csi_security.symbol} - #{csi_security.name} - in #{exchange.label}")
        listed_security = create_listed_security(csi_security, exchange, default_security_type)
        log("=> Listed Security=#{listed_security.to_hash}")
        log("=> Security=#{listed_security.security.to_hash}")
      when 1                                  # if one listed security found, update it
        listed_security = listed_securities.first
        security = listed_security.security
        if @similarity_measure.similarity(security.name.downcase, csi_security.name.downcase) >= APPROXIMATE_SEARCH_THRESHOLD
          log("Updating #{listed_security.symbol} (id=#{listed_security.id}) - #{security.name}")
          listed_security = update_listed_security(listed_security, csi_security, default_security_type)
          if listed_security
            log("=> Listed Security=#{listed_security.to_hash}")
            log("=> Security=#{listed_security.security.to_hash}")
          end
        else
          log("Creating #{csi_security.symbol} - #{csi_security.name} - in #{exchange.label}; ListedSecurity #{listed_security.to_hash} and Security #{security.to_hash} do not match CSI Security #{csi_security.inspect}")
          listed_security = create_listed_security(csi_security, exchange, default_security_type)
          log("=> Listed Security=#{listed_security.to_hash}")
          log("=> Security=#{listed_security.security.to_hash}")
        end
      else                                    # if multiple listed securities found, we have a data problem
        log("Error: There are multiple listed securities with symbol \"#{csi_security.symbol}\"")
      end
    else
      log("Exchange not found for security: #{csi_security.to_h}")
    end
  end


  # CsiData::Security is defined as
  # Struct.new(
  #   :csi_number,
  #   :symbol,
  #   :name,
  #   :exchange,
  #   :is_active,
  #   :start_date,
  #   :end_date,
  #   :sector,
  #   :industry,
  #   :conversion_factor,
  #   :switch_cf_date,
  #   :pre_switch_cf,
  #   :last_volume,
  #   :type,
  #   :sub_exchange,
  #   :currency
  # )
  def create_listed_security(csi_security, exchange, default_security_type)
    security = find_security_exact(csi_security.name, lookup_security_type(csi_security, default_security_type)) ||
                 create_security(csi_security, default_security_type)

    ListedSecurity.create(
      exchange_id: exchange.id,
      security_id: security.id,
      symbol: csi_security.symbol,
      listing_start_date: convert_date(csi_security.start_date),
      listing_end_date: convert_date(csi_security.end_date),
      csi_number: csi_security.csi_number.to_i
    )
  end

  # performs an exact security search by name
  def find_security_exact(name, security_type_name)
    Security.association_join(:security_type).select_all(:securities).where(security_type__name: security_type_name, securities__name: name).first
  end

  # performs an approximate security search by name
  def find_security_approximate(name, security_type_name)
    # security_names = Security.association_join(:security_type).where(security_type__name: security_type_name).select_map(:securities__name)
    db = SecurityNameDatabaseRegistry.get(security_type_name)
    search_key = extract_search_key_from_security_name(name)
    matches = db.ranked_search(search_key, APPROXIMATE_SEARCH_THRESHOLD)

    # search for securities by approximate matching against search_key
    securities = case matches.count
    when 0
      Security.association_join(:security_type).select_all(:securities).where(security_type__name: security_type_name, securities__name: name).to_a
    when 1
      Security.association_join(:security_type).select_all(:securities).where({security_type__name: security_type_name}, Sequel.or(securities__name: name, search_key: matches.first.value)).to_a
    else
      matching_names = matches.map {|match| "#{match.value} - #{match.score}" }
      best_match_search_key = matches.first.value
      search_key_best_match_score = matches.first.score
      if search_key_best_match_score == 1 ||
          is_match_correct?("Is \"#{best_match_search_key}\" a match for the search phrase \"#{search_key}\"? Score=#{matches.first.score} (Y/n) ")
        log("Warning: Searching for ambiguous security name. Search key #{search_key} (name=#{name}   security_type_name=#{security_type_name}) is being mapped to #{matching_names.first}. The #{matches.count} matches were:\n#{matching_names.join("\n")}")
        Security.association_join(:security_type).select_all(:securities).where({security_type__name: security_type_name}, Sequel.or(securities__name: name, search_key: best_match_search_key)).to_a
      else
        log("Warning: Searching for ambiguous security name. Search key #{search_key} (name=#{name}   security_type_name=#{security_type_name}) is NOT being mapped to #{matching_names.first}. The #{matches.count} matches were:\n#{matching_names.join("\n")}")
        []
      end
    end

    # figure out which of the matched securities is the closest name match
    case securities.count
    when 0
      nil
    when 1
      securities.first
    else
      db = SecurityNameDatabase.new
      security_name_to_security = securities.reduce({}) {|memo, security| memo[security.name.downcase] = security; memo }
      securities.each {|security| db.add(security.name.downcase) }
      matches = db.ranked_search(name.downcase, APPROXIMATE_SEARCH_THRESHOLD)
      case matches.count
      when 0
        closest_matching_security = prompt_multi_choice(securities, "Which of the following securities does \"#{name}\" identify?") {|security| security.name }
        log("Warning: Multiple securities found for search key #{search_key} (name=#{name}   security_type_name=#{security_type_name}). Closest match to \"#{name}\" is security id=#{closest_matching_security.id} name=#{closest_matching_security.name}")
        closest_matching_security
      when 1
        closest_matching_name = matches.first.value
        security_name_to_security[closest_matching_name]
      else
        match_names = matches.map(&:value)
        closest_matching_name = prompt_multi_choice(match_names, "Which of the following securities does \"#{name}\" identify?")
        closest_matching_security = security_name_to_security[closest_matching_name]
        log("Warning: Multiple securities found for search key #{search_key} (name=#{name}   security_type_name=#{security_type_name}). Closest match to \"#{name}\" is security id=#{closest_matching_security.id} name=#{closest_matching_security.name}")
        closest_matching_security
      end
    end
  end

  def is_match_correct?(prompt = "Is match correct? (Y/n): ")
    prompt_yes_no(prompt)
  end

  def prompt_yes_no(prompt = "(Y/n): ")
    print prompt
    yes_or_no = case STDIN.getch.strip.downcase
    when "y", ""
      true
    else
      false
    end
  end

  # Example:
  # irb> prompt_multi_choice([5,7,9]) {|item| item * 10 }
  # Enter the number corresponding to one of the following options:
  # 1. 50
  # 2. 70
  # 3. 90
  # 2
  # => 7
  def prompt_multi_choice(options, prompt = "Enter the number corresponding to one of the following options:", &option_text_extractor_fn)
    option_text_extractor_fn ||= lambda {|option| option.to_s }
    puts prompt
    options.each_with_index {|option, index| puts "#{index + 1}. #{option_text_extractor_fn.call(option)}" }
    selected_index = STDIN.gets.strip.to_i
    case
    when selected_index <= 0
      nil
    when selected_index <= options.count
      options[selected_index - 1]
    else
      nil
    end
  end

  def create_security(csi_security, default_security_type)
    security_type_name = lookup_security_type(csi_security, default_security_type)
    security = CreateSecurity.run(csi_security.name, security_type_name)
    start_date = csi_security.start_date ? convert_date(csi_security.start_date) : Date.today_datestamp
    #security.classify("Industry", "CSI", csi_security.industry || UNKNOWN_INDUSTRY_NAME, start_date)
    #security.classify("Sector", "CSI", csi_security.sector || UNKNOWN_SECTOR_NAME, start_date)
    security
  end

  # CsiData::Security is defined as
  # Struct.new(
  #   :csi_number,
  #   :symbol,
  #   :name,
  #   :exchange,
  #   :is_active,
  #   :start_date,
  #   :end_date,
  #   :sector,
  #   :industry,
  #   :conversion_factor,
  #   :switch_cf_date,
  #   :pre_switch_cf,
  #   :last_volume,
  #   :type,
  #   :sub_exchange,
  #   :currency
  # )
  def update_listed_security(listed_security, csi_security, default_security_type)
    security = listed_security.security

    # update Security
    replacement_attributes = {}

    security_type = find_or_create_security_type(lookup_security_type(csi_security, default_security_type))
    replacement_attributes[:security_type_id] = security_type.id if security.security_type_id != security_type.id

    replacement_attributes[:name] = csi_security.name if security.name != csi_security.name
    replacement_attributes[:search_key] = extract_search_key_from_security_name(csi_security.name) if security.name != csi_security.name

    if !replacement_attributes.empty?
      log("Updating security:\n#{security.to_hash}\n=> #{replacement_attributes.inspect}")
      security.update(replacement_attributes)
    end

    # potentially update security's industry and sector classifications
    #csi_industry = csi_security.industry || UNKNOWN_INDUSTRY_NAME
    #security.classify("Industry", "CSI", csi_industry, Date.today_datestamp)

    #csi_sector = csi_security.sector || UNKNOWN_SECTOR_NAME
    #security.classify("Sector", "CSI", csi_sector, Date.today_datestamp)


    # update ListedSecurity
    replacement_attributes = {}
    replacement_attributes[:symbol] = csi_security.symbol if listed_security.symbol != csi_security.symbol
    replacement_attributes[:listing_start_date] = convert_date(csi_security.start_date) if listed_security.listing_start_date != convert_date(csi_security.start_date)
    replacement_attributes[:listing_end_date] = convert_date(csi_security.end_date) if listed_security.listing_end_date != convert_date(csi_security.end_date)
    replacement_attributes[:csi_number] = csi_security.csi_number.to_i if listed_security.csi_number != csi_security.csi_number.to_i

    if !replacement_attributes.empty?
      log("Updating listed security:\n#{listed_security.to_hash}\n=> #{replacement_attributes.inspect}")
      listed_security.update(replacement_attributes)
    end

    listed_security
  rescue Sequel::ValidationFailed, Sequel::HookFailed => e
    log "Can't import #{csi_security.inspect}: #{e.message}"
    nil
  rescue => e
    log "Can't import #{csi_security.inspect}: #{e.message}"
    log e.backtrace.join("\n")
    nil
  end


  # csi_date is a string of the form "1993-02-01"
  # returns the integer yyyymmdd representation of the csi_date
  def convert_date(csi_date)
    if csi_date
      csi_date.gsub("-","").to_i unless csi_date.empty?
    end
  end

  def lookup_security_type(csi_security, default_security_type)
    if csi_security.type.nil? || csi_security.type == UNKNOWN_SECURITY_TYPE
      default_security_type
    else
      csi_security.type
    end
  end

  def extract_search_key_from_security_name(security_name)
    security_name.downcase
  end

  def find_or_create_security_type(security_type_name)
    if security_type_name && !security_type_name.empty?
      SecurityType.first(name: security_type_name) || SecurityType.create(name: security_type_name)
    end
  end

end
