# frozen_string_literal: true

# Runs a PuppetDB query, and answers with an empty list when PuppetDB is down or
# the function isn't there at all. A scanner host should still converge the rest
# of its catalogue when PuppetDB can't answer.
Puppet::Functions.create_function(:'openvas::puppetdb_rows', Puppet::Functions::InternalFunction) do
  # @param query The PQL query.
  # @return The rows, or an empty list.
  dispatch :rows do
    scope_param
    param 'String[1]', :query
  end

  def rows(scope, query)
    scope.call_function('puppetdb_query', [query])
  rescue StandardError => e
    Puppet.warning("openvas::puppetdb_rows: #{e.message}")
    []
  end
end
