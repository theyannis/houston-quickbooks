return {
	scenario = {publisher = {}, config = {access = "read-write", environment = "production", company_id = "123145000000000", client_id = "fixture-client", client_secret = "fixture-secret"}, auth_method = "intuit", auth_config = {}},
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
		assert(qbo.createEntity ~= nil and qbo.updateEntity ~= nil and qbo.deleteEntity ~= nil and qbo.voidTransaction ~= nil, "read-write surface lacks writes")
		local help = qbo.help()
		assert(string.find(help, "request_id", 1, true) and not string.find(help, "sandbox", 1, true), "help does not describe writes")
		local base = "https://quickbooks.api.intuit.com/v3/company/123145000000000/"

		table.insert(responses, '{"Invoice":{"Id":"201","SyncToken":"0","TotalAmt":150},"time":"t"}')
		local created = qbo.createEntity({entity = "Invoice", request_id = "inv-2026-0001",
			body = {CustomerRef = {value = "58"}, Line = {{Amount = 150, DetailType = "SalesItemLineDetail", SalesItemLineDetail = {ItemRef = {value = "1"}}}}}})
		assert(created.Id == "201")
		assert(requests[1].method == "POST" and requests[1].url == base .. "invoice?requestid=inv-2026-0001&minorversion=75", requests[1].url)
		assert(requests[1].headers["Content-Type"][1] == "application/json")
		local sent = json.decode(requests[1].body)
		assert(sent.CustomerRef.value == "58" and sent.Line[1].Amount == 150)

		table.insert(responses, '{"Customer":{"Id":"58","SyncToken":"3","Active":false},"time":"t"}')
		assert(qbo.updateEntity({entity = "Customer", body = {Id = "58", SyncToken = "2", Active = false}}).SyncToken == "3")
		assert(requests[2].url == base .. "customer?minorversion=75", requests[2].url)
		local update = json.decode(requests[2].body)
		assert(update.sparse == true and update.Id == "58" and update.Active == false, "update is not sparse")

		table.insert(responses, '{"Vendor":{"Id":"7","SyncToken":"1"},"time":"t"}')
		qbo.updateEntity({entity = "Vendor", body = {Id = "7", SyncToken = "0", DisplayName = "Acme"}, sparse = false})
		assert(json.decode(requests[3].body).sparse == false, "full update was sent sparse")

		table.insert(responses, '{"Invoice":{"Id":"201","status":"Deleted","domain":"QBO"},"time":"t"}')
		assert(qbo.deleteEntity({entity = "Invoice", id = "201", sync_token = "1", request_id = "del-201"}).status == "Deleted")
		assert(requests[4].url == base .. "invoice?operation=delete&requestid=del-201&minorversion=75", requests[4].url)
		local deleted = json.decode(requests[4].body)
		assert(deleted.Id == "201" and deleted.SyncToken == "1")

		table.insert(responses, '{"Invoice":{"Id":"202","SyncToken":"2","TotalAmt":0},"time":"t"}')
		qbo.voidTransaction({entity = "Invoice", id = "202", sync_token = "1"})
		assert(requests[5].url == base .. "invoice?operation=void&minorversion=75", requests[5].url)

		table.insert(responses, '{"Payment":{"Id":"90","SyncToken":"2","TotalAmt":0},"time":"t"}')
		qbo.voidTransaction({entity = "Payment", id = "90", sync_token = "1"})
		assert(requests[6].url == base .. "payment?operation=update&include=void&minorversion=75", requests[6].url)
		assert(json.decode(requests[6].body).sparse == true)

		local count = #requests
		for _, bad in {
			function() qbo.createEntity({entity = "Invoice", body = {Id = "1"}}) end,
			function() qbo.createEntity({entity = "TaxRate", body = {Name = "x"}}) end,
			function() qbo.createEntity({entity = "Invoice", body = {}}) end,
			function() qbo.updateEntity({entity = "Customer", body = {Id = "58"}}) end,
			function() qbo.deleteEntity({entity = "Customer", id = "58", sync_token = "1"}) end,
			function() qbo.voidTransaction({entity = "Bill", id = "1", sync_token = "0"}) end,
			function() qbo.createEntity({entity = "Invoice", body = {CustomerRef = {value = "1"}}, request_id = "has spaces"}) end,
		} do
			assert(not pcall(bad), "invalid write was accepted")
		end
		assert(#requests == count, "an invalid write reached QuickBooks")
	end,
}
