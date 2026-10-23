return {
	scenario = {publisher = {}, config = {company_id = "9341450000000001", client_id = "fixture-client", client_secret = "fixture-secret"}, auth_method = "intuit", auth_config = {}},
	configure = function()
		requests = {}
		responses = {}
		http = {request = function(req)
			table.insert(requests, req)
			local payload = table.remove(responses, 1) or "{}"
			return fixture.operation({statusCode = 200, headers = {}, body = fixture.reader(payload)})
		end}
	end,
	run = function(qbo)
		assert(qbo.createEntity == nil and qbo.updateEntity == nil and qbo.deleteEntity == nil and qbo.voidTransaction == nil, "read-only surface exposes writes")
		assert(qbo.query ~= nil and qbo.getReport ~= nil and qbo.getChanges ~= nil, "read surface is incomplete")
		local help = qbo.help()
		assert(string.find(help, "Read-only connections omit writes.", 1, true) and string.find(help, "sandbox", 1, true), "help does not describe the surface")
		assert(not string.find(help, "createEntity", 1, true), "help lists a write")

		local base = "https://sandbox-quickbooks.api.intuit.com/v3/company/9341450000000001"
		table.insert(responses, '{"CompanyInfo":{"CompanyName":"Sandbox Company_US_1","Id":"1"},"time":"2026-10-23T15:00:00-07:00"}')
		assert(qbo.getCompanyInfo().CompanyName == "Sandbox Company_US_1")
		assert(requests[1].method == "GET" and requests[1].url == base .. "/companyinfo/9341450000000001?minorversion=75", requests[1].url)
		assert(requests[1].headers.Accept[1] == "application/json" and requests[1].body == nil)

		table.insert(responses, '{"QueryResponse":{"Invoice":[{"Id":"130","TotalAmt":150}],"startPosition":1,"maxResults":1},"time":"t"}')
		local page = qbo.query({query = "select * from Invoice where Balance > '0'"})
		assert(page.entity == "Invoice" and page.items[1].Id == "130" and page.start_position == 1 and page.max_results == 1)
		assert(requests[2].url == base .. "/query?query=select%20%2A%20from%20Invoice%20where%20Balance%20%3E%20%270%27&minorversion=75", requests[2].url)

		table.insert(responses, '{"QueryResponse":{},"time":"t"}')
		local empty = qbo.query({query = "SELECT * FROM Bill"})
		assert(empty.entity == nil and #empty.items == 0 and json.encode(empty.items) == "[]", "empty query is not an empty array")

		table.insert(responses, '{"QueryResponse":{"totalCount":42},"time":"t"}')
		assert(qbo.query({query = "select count(*) from Customer"}).total_count == 42)

		table.insert(responses, '{"Customer":{"Id":"58","DisplayName":"Amy"},"time":"t"}')
		assert(qbo.getEntity({entity = "Customer", id = 58}).DisplayName == "Amy")
		assert(requests[5].url == base .. "/customer/58?minorversion=75", requests[5].url)

		table.insert(responses, '{"Header":{"ReportName":"ProfitAndLoss"},"Columns":{"Column":[]},"Rows":{"Row":[]}}')
		local report = qbo.getReport({report = "ProfitAndLoss", start_date = "2026-01-01", end_date = "2026-09-30", customer = {"1", "2"}})
		assert(report.Header.ReportName == "ProfitAndLoss")
		assert(requests[6].url == base .. "/reports/ProfitAndLoss?customer=1,2&end_date=2026-09-30&start_date=2026-01-01&minorversion=75", requests[6].url)

		table.insert(responses, '{"Preferences":{"CurrencyPrefs":{"MultiCurrencyEnabled":false}},"time":"t"}')
		assert(qbo.getPreferences().CurrencyPrefs.MultiCurrencyEnabled == false)
		assert(requests[7].url == base .. "/preferences?minorversion=75")

		table.insert(responses, '{"CDCResponse":[{"QueryResponse":[{"Customer":[{"Id":"58"},{"Id":"9","status":"Deleted"}],"startPosition":1}]}],"time":"t"}')
		local changes = qbo.getChanges({entities = {"Customer", "Invoice"}, changed_since = "2026-10-01T00:00:00-07:00"})
		assert(#changes.changes.Customer == 2 and changes.changes.Customer[2].status == "Deleted")
		assert(#changes.changes.Invoice == 0 and json.encode(changes.changes.Invoice) == "[]", "unchanged entity is not an empty array")
		assert(requests[8].url == base .. "/cdc?entities=Customer%2CInvoice&changedSince=2026-10-01T00%3A00%3A00-07%3A00&minorversion=75", requests[8].url)

		local count = #requests
		for _, bad in {
			function() qbo.query({query = "delete from Invoice"}) end,
			function() qbo.query({query = "select * from Invoice", extra = 1}) end,
			function() qbo.getEntity({entity = "Widget", id = "1"}) end,
			function() qbo.getEntity({entity = "Invoice", id = "../1"}) end,
			function() qbo.getReport({report = "../ProfitAndLoss"}) end,
			function() qbo.getReport({report = "BalanceSheet", ["Start-Date"] = "x"}) end,
			function() qbo.getChanges({entities = {}, changed_since = "2026-10-01"}) end,
		} do
			assert(not pcall(bad), "invalid arguments were accepted")
		end
		assert(#requests == count, "invalid arguments reached QuickBooks")
	end,
}
