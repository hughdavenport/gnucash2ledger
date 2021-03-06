require 'nokogiri'
require 'date'
require 'active_support/core_ext'

module G2L
  class Input
    attr_accessor :input

    def initialize(input)
      self.input = input
    end

    def to_ledger
      doc = Nokogiri::XML(input)

      accounts = doc.xpath('//gnc:account').inject({}) do |all, account|
        id = account.xpath("act:id")[0].text
        parent = account.xpath("act:parent")[0]

        all.update(id => {
          :name      => account.xpath("act:name")[0].text,
          :commodity => account.xpath("act:commodity/cmdty:id")[0].try(:text),
          :parent    => parent ? parent.text : nil
        })
      end

      accounts = resolve_accounts(accounts)

      transactions = doc.xpath('//gnc:transaction').map do |transaction|
        {
          :date        => Date.parse(transaction.xpath("trn:date-posted/ts:date")[0].text),
          :description => transaction.xpath("trn:description")[0].text,
          :splits => transaction.xpath("trn:splits/trn:split").map {|split| {
            :account    => split.xpath("split:account")[0].text,
            :action     => split.xpath("split:action")[0].try(:text),
            :value      => parse_value(split.xpath("split:value")[0]),
            :quantity   => parse_value(split.xpath("split:quantity")[0]),
            :reconciled => split.xpath("split:reconciled-state")[0].text == 'y'
          }}
        }
      end

      # Generate output
      transactions.sort_by {|x| x[:date] }.map do |tx|
        (["%s %s%s" % [
          tx[:date].strftime("%Y/%m/%d"),
          tx[:splits].any? {|y| y[:reconciled] } ? '* ' : '',
          tx[:description]
        ]] + tx[:splits].map {|split|
          account = accounts[split[:account]]

          value = if split[:action]
            "%i %s" % [split[:quantity].to_i, account[:commodity]]
          else
            '$' + split[:quantity].to_s
          end
          "  %-44s%s" % [account[:name], value]
        }).join("\n")
      end.join("\n\n")
    end

    private

    # Shelved
    def to_xml
      builder = Nokogiri::XML::Builder.new do |xml|
        xml.ledger('xmlns:tr' => '', 'xmlns:en' => '') {
          transactions.each do |tx|
            xml.entry {
              xml['en'].date(tx[:date].strftime("%Y/%m/%d"))
              xml['en'].payee(tx[:description])
              xml['en'].cleared if tx[:splits].any? {|x| x[:reconciled]}
              xml['en'].transactions {
                tx[:splits].each do |split|
                  xml.transaction {
                    xml['tr'].account accounts[split[:account]][:name]
                    xml.value(:type => 'amount') {
                      xml.commodity(:flags => 'PT') {
                        xml.symbol '$'
                      }
                      xml.quantity split[:value]
                    }
                  }
                end
              }
            }
          end
        }
      end
      builder.to_xml
    end

    def parse_value(value)
      if value
        value.text.split("/").map(&:to_f).inject {|a, b| a / b }
      else
        0
      end
    end

    def resolve_accounts(accounts)
      resolve_name = lambda do |id|
        if accounts[id][:parent]
          [resolve_name[accounts[id][:parent]], accounts[id][:name]].flatten.join(':')
        else
          []
        end
      end

      accounts.inject({}) do |a, (id, account)|
        a.update(id => account.merge(:name => resolve_name[id]))
      end
    end
  end
end
