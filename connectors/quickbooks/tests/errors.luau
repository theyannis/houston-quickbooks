return {
	scenario = {publisher = {}, config = {access = "read-write", company_id = "9341450000000001", client_id = "fixture-client", client_secret = "fixture-secret"}, auth_method = "intuit", auth_config = {}},
	configure = function()
		calls = 0
		status = 200
		payload = "{}"
		responseHeaders = {}
		http = {request = function(req)
			calls += 1
			return fixture.operation({statusCode = status, headers = responseHeaders, body = fixture.reader(payload)})
		end}
	end,
	run = function(qbo)
		local function upstream(code, body, headers, expected, call)
			status, payload, responseHeaders = code, body, headers
			local before = calls
			local ok, err = pcall(call)
			for _, text in expected do
				assert(not ok and string.find(tostring(err), text, 1, true), "missing " .. text .. " in " .. tostring(err))
			end
			assert(calls == before + 1, "failed request was retried")
			return tostring(err)
		end
		local function create() qbo.createEntity({entity = "Customer", body = {DisplayName = "Amy"}}) end
		local function createWithId() qbo.createEntity({entity = "Customer", body = {DisplayName = "Amy"}, request_id = "c-1"}) end
		local function read() qbo.getEntity({entity = "Invoice", id = "1"}) end

		upstream(400, '{"Fault":{"Error":[{"Message":"Duplicate Name Exists Error","Detail":"The name supplied already exists. : Id=58","code":"6240"}],"type":"ValidationFault"},"time":"t"}',
			{["intuit_tid"] = {"1-abc"}}, {"QuickBooks HTTP 400: ValidationFault; 6240 Duplicate Name Exists Error The name supplied already exists.", "(intuit_tid 1-abc)", '"retryable":false'}, create)
		upstream(400, '{"Fault":{"Error":[{"Message":"Stale Object Error","Detail":"You and abc@example.com were working on this at the same time.","code":"5010"}],"type":"ValidationFault"}}',
			{}, {"5010 Stale Object Error"}, function() qbo.updateEntity({entity = "Customer", body = {Id = "58", SyncToken = "1", Active = false}}) end)
		upstream(401, '{"fault":{"error":[{"message":"message=AuthenticationFailed; errorCode=003200; statusCode=401","detail":"Token expired","code":"3200"}],"type":"AUTHENTICATION"}}',
			{}, {"QuickBooks HTTP 401: AUTHENTICATION; 3200 message=AuthenticationFailed", '"retryable":false'}, read)
		upstream(401, "", {}, {"QuickBooks HTTP 401: the sign-in expired"}, read)
		upstream(403, '{"Fault":{"Error":[{"Message":"Unsupported Operation","code":"500"}],"type":"ValidationFault"}}', {}, {"QuickBooks HTTP 403", '"upstream_status":403'}, read)
		upstream(429, "", {}, {"QuickBooks HTTP 429: rate limited", '"retryable":true'}, create)
		upstream(500, "<html>error</html>", {}, {"QuickBooks HTTP 500", '"retryable":true'}, read)
		upstream(503, "", {}, {"QuickBooks HTTP 503", '"retryable":false'}, create)
		upstream(503, "", {}, {"QuickBooks HTTP 503", '"retryable":true'}, createWithId)
		upstream(200, '{"Fault":{"Error":[{"Message":"Object Not Found","code":"610"}],"type":"ValidationFault"},"time":"t"}', {}, {"QuickBooks HTTP 200: ValidationFault; 610 Object Not Found"}, read)
		upstream(200, "<html>Maintenance</html>", {}, {"invalid JSON"}, read)
		upstream(200, '"text"', {}, {"invalid JSON"}, function() qbo.getPreferences() end)
		upstream(200, '{"time":"t"}', {}, {"QuickBooks returned no Invoice"}, read)
		local long = upstream(400, json.encode({Fault = {type = "ValidationFault", Error = {{code = "2020", Message = string.rep("x", 5000)}}}}), {}, {"2020 xxx"}, create)
		assert(not string.find(long, string.rep("x", 301), 1, true), "error message not bounded")
	end,
}
