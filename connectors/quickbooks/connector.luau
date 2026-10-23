-- QuickBooks Online Accounting API v3 (minorversion 75), checked on 2026-10-23 against
-- https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/account.
-- Arguments and results keep QuickBooks' PascalCase entity and field names.
type Options = {[string]: any}

local API = if config.environment == "production" then "https://quickbooks.api.intuit.com" else "https://sandbox-quickbooks.api.intuit.com"
local MINOR_VERSION = "75"
local DOCS = "https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/"

local function set(names: {string}): {[string]: boolean}
	local result: {[string]: boolean} = {}
	for _, name in names do result[name] = true end
	return table.freeze(result)
end

-- Entities read by ID or with query. Budget, CompanyCurrency, CustomerType, TaxAgency, TaxCode
-- and TaxRate are read-only through this connector.
local READABLE = set({
	"Account", "Attachable", "Bill", "BillPayment", "Budget", "Class", "CompanyCurrency", "CreditMemo",
	"Customer", "CustomerType", "Department", "Deposit", "Employee", "Estimate", "Invoice", "Item",
	"JournalEntry", "Payment", "PaymentMethod", "Purchase", "PurchaseOrder", "RefundReceipt",
	"SalesReceipt", "TaxAgency", "TaxCode", "TaxRate", "Term", "TimeActivity", "Transfer", "Vendor",
	"VendorCredit",
})
local WRITABLE = set({
	"Account", "Attachable", "Bill", "BillPayment", "Class", "CreditMemo", "Customer", "Department",
	"Deposit", "Employee", "Estimate", "Invoice", "Item", "JournalEntry", "Payment", "PaymentMethod",
	"Purchase", "PurchaseOrder", "RefundReceipt", "SalesReceipt", "Term", "TimeActivity", "Transfer",
	"Vendor", "VendorCredit",
})
-- Transactions can be deleted; list entities (customers, vendors, accounts, items...) are
-- deactivated instead, by updating Active=false.
local DELETABLE = set({
	"Attachable", "Bill", "BillPayment", "CreditMemo", "Deposit", "Estimate", "Invoice", "JournalEntry",
	"Payment", "Purchase", "PurchaseOrder", "RefundReceipt", "SalesReceipt", "TimeActivity", "Transfer",
	"VendorCredit",
})
local VOIDABLE = set({"BillPayment", "Invoice", "Payment", "SalesReceipt"})

local function names(entities: {[string]: boolean}): string
	local list: {string} = {}
	for name in entities do table.insert(list, name) end
	table.sort(list)
	return table.concat(list, ", ")
end

local function options(input: Options?, allowed: {string}, operation: string): Options
	if input == nil then return {} end
	assert(type(input) == "table", operation .. ": opts must be an object")
	for key in input do
		assert(type(key) == "string", operation .. ": opts must have named fields")
		assert(table.find(allowed, key) ~= nil, operation .. " has no option " .. key)
	end
	return input
end

local function realm(): string
	local id = config.company_id
	if type(id) ~= "string" or string.match(id, "^%d+$") == nil or #id > 32 then
		error("The connection's QuickBooks company ID must be the numeric Realm ID; ask a connection admin to correct it")
	end
	return id
end

local function entityName(value: any, allowed: {[string]: boolean}, operation: string): string
	assert(type(value) == "string" and allowed[value] == true, operation .. ": entity must be one of " .. names(allowed))
	return value
end

-- Most QuickBooks IDs are digits; a few, such as the US TaxCode IDs TAX and NON, are letters.
local function identifier(value: any, field: string): string
	if type(value) == "number" then
		assert(value >= 0 and value % 1 == 0 and value <= 9007199254740991, field .. " must be a QuickBooks ID")
		return string.format("%d", value)
	end
	assert(type(value) == "string" and string.match(value, "^[%w%-]+$") ~= nil and #value <= 64, field .. " must be a QuickBooks ID")
	return value
end

-- QuickBooks' requestid makes a write idempotent: repeating it returns the first result.
local function requestId(value: any): string?
	if value == nil then return nil end
	assert(type(value) == "string" and string.match(value, "^[%w%-]+$") ~= nil and #value <= 50,
		"request_id must be up to 50 letters, digits or dashes")
	return value
end

local function header(response: HttpResponse, name: string): string?
	local values = response.headers[name]
	return if values then values[1] else nil
end

local function text(value: any): string?
	if type(value) == "string" and value ~= "" then return string.sub(value, 1, 300) end
	if type(value) == "number" then return tostring(value) end
	return nil
end

-- Faults are {Fault={type, Error={{code, Message, Detail, element}}}}; authentication faults
-- sometimes use lowercase keys.
local function fault(value: any): string?
	if type(value) ~= "table" then return nil end
	local node = value.Fault or value.fault
	if type(node) ~= "table" then return nil end
	local parts: {string} = {}
	local kind = text(node.type)
	if kind then table.insert(parts, kind) end
	local errors = node.Error or node.error
	if type(errors) == "table" then
		for _, item in errors do
			if type(item) == "table" and #parts < 6 then
				local bits: {string} = {}
				for _, field in {"code", "Message", "Detail", "element"} do
					local piece = text(item[field]) or text(item[string.lower(field)])
					if piece then table.insert(bits, piece) end
				end
				if #bits > 0 then table.insert(parts, table.concat(bits, " ")) end
			end
		end
	end
	return if #parts > 0 then table.concat(parts, "; ") else "QuickBooks fault"
end

local function failure(operation: string, status: number, message: string, retryable: boolean): never
	return houston.fail({operation = operation, layer = "upstream", upstream_status = status,
		retryable = retryable, message = message})
end

-- One request against the connected company. retrySafe tells whether a 5xx can be repeated
-- safely: reads and writes carrying a request_id.
local function call(operation: string, method: string, path: string, params: {string}, payload: any?, retrySafe: boolean): any
	local parts = table.clone(params)
	table.insert(parts, "minorversion=" .. MINOR_VERSION)
	local headers: HttpHeaders = {Accept = {"application/json"}}
	local encoded: string? = nil
	if payload ~= nil then
		headers["Content-Type"] = {"application/json"}
		encoded = json.encode(payload)
	end
	local response = await(http.request({
		method = method,
		url = API .. "/v3/company/" .. realm() .. path .. "?" .. table.concat(parts, "&"),
		headers = headers,
		body = encoded,
	}))
	local status = response.statusCode
	local success = status >= 200 and status < 300
	local raw = if success then await(response.body:readAll()) else await(response.body:readPrefix(16384))
	local ok, value = pcall(json.decode, raw)
	local decoded = if ok then value else nil
	local detail = fault(decoded)
	if not success or detail ~= nil then
		local message = "QuickBooks HTTP " .. tostring(status)
		if detail then
			message ..= ": " .. detail
		elseif status == 401 then
			message ..= ": the sign-in expired or was revoked; select Set up again on the connection"
		elseif status == 429 then
			message ..= ": rate limited"
		end
		local tid = header(response, "intuit_tid")
		if tid then message ..= " (intuit_tid " .. string.sub(tid, 1, 80) .. ")" end
		return failure(operation, status, message, status == 429 or (status >= 500 and retrySafe))
	end
	if type(decoded) ~= "table" or string.match(raw, "^%s*{") == nil then
		return failure(operation, status, "QuickBooks returned an invalid JSON object", false)
	end
	return decoded
end

local function unwrap(operation: string, decoded: any, key: string): any
	local value = decoded[key]
	if type(value) ~= "table" then
		return failure(operation, 200, "QuickBooks returned no " .. key, false)
	end
	return value
end

local function scalar(value: any, field: string): string
	local kind = type(value)
	assert(kind == "string" or kind == "number" or kind == "boolean", field .. " must be a string, number, boolean or array of those")
	return url.encode(value)
end

local function getCompanyInfo(): any
	local id = realm()
	return unwrap("getCompanyInfo", call("getCompanyInfo", "GET", "/companyinfo/" .. id, {}, nil, true), "CompanyInfo")
end

local function getPreferences(): any
	return unwrap("getPreferences", call("getPreferences", "GET", "/preferences", {}, nil, true), "Preferences")
end

local function query(input: Options?): any
	local args = options(input, {"query"}, "query")
	local statement = args.query
	assert(type(statement) == "string" and string.match(string.lower(statement), "^%s*select%s") ~= nil,
		"query must be a QuickBooks SELECT statement")
	assert(#statement <= 4000, "query must be at most 4000 characters")
	local response = unwrap("query", call("query", "GET", "/query", {"query=" .. url.encode(statement)}, nil, true), "QueryResponse")
	local items: {any} = json.decode("[]")
	local entity: string? = nil
	for key, value in response do
		if type(key) == "string" and type(value) == "table" then
			entity = key
			items = value
		end
	end
	return {entity = entity, items = items, start_position = response.startPosition,
		max_results = response.maxResults, total_count = response.totalCount}
end

local function getEntity(input: Options?): any
	local args = options(input, {"entity", "id"}, "getEntity")
	local entity = entityName(args.entity, READABLE, "getEntity")
	local id = identifier(args.id, "id")
	return unwrap("getEntity", call("getEntity", "GET", "/" .. string.lower(entity) .. "/" .. id, {}, nil, true), entity)
end

local function getReport(input: Options?): any
	assert(input == nil or type(input) == "table", "getReport: opts must be an object")
	local args: Options = input or {}
	local report = args.report
	assert(type(report) == "string" and string.match(report, "^%u%w+$") ~= nil and #report <= 64,
		"report must be a QuickBooks report name such as ProfitAndLoss")
	local keys: {string} = {}
	for key in args do
		assert(type(key) == "string", "getReport: opts must have named fields")
		if key ~= "report" then
			assert(string.match(key, "^[%l_]+$") ~= nil and #key <= 64, "getReport: report parameters are snake_case, such as start_date")
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local parts: {string} = {}
	for _, key in keys do
		local value = args[key]
		local encoded: {string} = {}
		if type(value) == "table" then
			for index, item in value do
				assert(type(index) == "number" and index == #encoded + 1, key .. " must be an array, not an object")
				table.insert(encoded, scalar(item, key))
			end
			assert(#encoded > 0, key .. " must not be an empty array")
		else
			table.insert(encoded, scalar(value, key))
		end
		table.insert(parts, key .. "=" .. table.concat(encoded, ","))
	end
	return call("getReport", "GET", "/reports/" .. report, parts, nil, true)
end

local function getChanges(input: Options?): any
	local args = options(input, {"entities", "changed_since"}, "getChanges")
	local list = args.entities
	assert(type(list) == "table", "entities must be an array of entity names")
	local requested: {string} = {}
	for index, name in list do
		assert(type(index) == "number" and index == #requested + 1, "entities must be an array, not an object")
		table.insert(requested, entityName(name, READABLE, "getChanges"))
	end
	assert(#requested > 0 and #requested <= 30, "entities must list 1 to 30 entity names")
	local since = args.changed_since
	assert(type(since) == "string" and string.match(since, "^%d%d%d%d%-%d%d%-%d%d") ~= nil,
		"changed_since must be an ISO 8601 date or date-time, such as 2026-10-01T00:00:00-07:00")
	local decoded = call("getChanges", "GET", "/cdc",
		{"entities=" .. url.encode(table.concat(requested, ",")), "changedSince=" .. url.encode(since)}, nil, true)
	local changes: {[string]: any} = {}
	for _, name in requested do changes[name] = json.decode("[]") end
	local cdc = decoded.CDCResponse
	if type(cdc) == "table" then
		for _, block in cdc do
			if type(block) == "table" and type(block.QueryResponse) == "table" then
				for _, response in block.QueryResponse do
					if type(response) == "table" then
						for key, value in response do
							if type(key) == "string" and type(value) == "table" and changes[key] ~= nil then
								changes[key] = value
							end
						end
					end
				end
			end
		end
	end
	return {changes = changes, time = decoded.time}
end

local function body(value: any, operation: string): Options
	assert(type(value) == "table" and next(value) ~= nil, operation .. ": body must be a nonempty object of QuickBooks fields")
	for key in value do assert(type(key) == "string", operation .. ": body must be an object") end
	return table.clone(value)
end

local function write(operation: string, entity: string, params: {string}, payload: Options, rid: string?): any
	local parts = table.clone(params)
	if rid then table.insert(parts, "requestid=" .. rid) end
	return unwrap(operation, call(operation, "POST", "/" .. string.lower(entity), parts, payload, rid ~= nil), entity)
end

local function createEntity(input: Options?): any
	local args = options(input, {"entity", "body", "request_id"}, "createEntity")
	local entity = entityName(args.entity, WRITABLE, "createEntity")
	local payload = body(args.body, "createEntity")
	assert(payload.Id == nil, "createEntity: body must not contain Id; use updateEntity")
	return write("createEntity", entity, {}, payload, requestId(args.request_id))
end

local function updateEntity(input: Options?): any
	local args = options(input, {"entity", "body", "sparse", "request_id"}, "updateEntity")
	local entity = entityName(args.entity, WRITABLE, "updateEntity")
	local payload = body(args.body, "updateEntity")
	identifier(payload.Id, "body.Id")
	identifier(payload.SyncToken, "body.SyncToken")
	assert(args.sparse == nil or type(args.sparse) == "boolean", "sparse must be a boolean")
	payload.sparse = args.sparse ~= false
	return write("updateEntity", entity, {}, payload, requestId(args.request_id))
end

local function deleteEntity(input: Options?): any
	local args = options(input, {"entity", "id", "sync_token", "request_id"}, "deleteEntity")
	local entity = entityName(args.entity, DELETABLE, "deleteEntity")
	local payload: Options = {Id = identifier(args.id, "id"), SyncToken = identifier(args.sync_token, "sync_token")}
	return write("deleteEntity", entity, {"operation=delete"}, payload, requestId(args.request_id))
end

local function voidTransaction(input: Options?): any
	local args = options(input, {"entity", "id", "sync_token", "request_id"}, "voidTransaction")
	local entity = entityName(args.entity, VOIDABLE, "voidTransaction")
	local payload: Options = {Id = identifier(args.id, "id"), SyncToken = identifier(args.sync_token, "sync_token")}
	-- A Payment is voided through a sparse update; the other entities have a void operation.
	local operation = {"operation=void"}
	if entity == "Payment" then
		payload.sparse = true
		operation = {"operation=update", "include=void"}
	end
	return write("voidTransaction", entity, operation, payload, requestId(args.request_id))
end

local about: {[string]: string} = {
	getCompanyInfo = "getCompanyInfo(): the connected company's CompanyInfo (CompanyName, LegalName, addresses, FiscalYearStartMonth, Country). Start here to confirm which company is connected.",
	getPreferences = "getPreferences(): the company's Preferences (accounting, sales forms, currency, tax and time-tracking settings), including whether multicurrency, classes or departments are on.",
	query = "query({query}): runs one QuickBooks SELECT statement, such as \"select * from Invoice where Balance > '0' order by DueDate startposition 1 maxresults 100\". Returns {entity, items, start_position, max_results, total_count}; items is an empty array when nothing matches. Pages hold at most 1000 rows (100 by default): raise startposition by maxresults until fewer come back. \"select count(*) from Customer\" fills total_count only. The language has no joins, OR or SELECT of nested fields; filter by reference with CustomerRef = '58'. Quote values in single quotes; dates are 'YYYY-MM-DD'. See " .. DOCS .. "<entity> for each entity's queryable fields.",
	getEntity = "getEntity({entity, id}): one record, such as getEntity({entity='Invoice', id='130'}). Readable entities: " .. names(READABLE) .. ".",
	getReport = "getReport({report, ...parameters}): a report as QuickBooks returns it, {Header, Columns={Column}, Rows={Row}}, where rows nest by section (Row.Header, Row.Rows, Row.Summary) and each ColData value is a string. Reports include ProfitAndLoss, ProfitAndLossDetail, BalanceSheet, CashFlow, TrialBalance, GeneralLedger, AgedReceivables, AgedReceivableDetail, AgedPayables, AgedPayableDetail, CustomerBalance, CustomerBalanceDetail, CustomerIncome, CustomerSales, VendorBalance, VendorBalanceDetail, VendorExpenses, ItemSales, ClassSales, DepartmentSales, InventoryValuationSummary, TransactionList and AccountList. Parameters use QuickBooks' snake_case names, for example start_date and end_date ('YYYY-MM-DD'), date_macro ('This Fiscal Year', 'Last Month'...), accounting_method ('Accrual' or 'Cash'), summarize_column_by ('Month', 'Quarter', 'Customers'...), customer, vendor, item, class or department (IDs; arrays are joined with commas). See https://developer.intuit.com/app/developer/qbo/docs/api/accounting/report-entities/profitandloss.",
	getChanges = "getChanges({entities, changed_since}): records of those entities created, changed or deleted since changed_since (ISO 8601, within the last 30 days), as {changes={[entity]=records}, time}. Deleted records carry status='Deleted'. At most 1000 records per entity come back; use a later changed_since or query for more.",
	createEntity = "createEntity({entity, body, request_id?}): creates a record and returns it with its Id and SyncToken. body uses QuickBooks' fields, for example createEntity({entity='Invoice', body={CustomerRef={value='58'}, Line={{Amount=150, DetailType='SalesItemLineDetail', SalesItemLineDetail={ItemRef={value='1'}}}}}}). Writable entities: " .. names(WRITABLE) .. ".",
	updateEntity = "updateEntity({entity, body, sparse?, request_id?}): body must include the record's Id and current SyncToken (read it just before); a stale SyncToken fails with code 5010, so read again and reapply. sparse defaults to true, changing only the fields in body; sparse=false replaces the whole record and clears omitted fields. Deactivate customers, vendors, accounts, items and other list entities with Active=false; they cannot be deleted.",
	deleteEntity = "deleteEntity({entity, id, sync_token, request_id?}): permanently deletes a transaction; QuickBooks keeps it only in its audit log. Deletable: " .. names(DELETABLE) .. ".",
	voidTransaction = "voidTransaction({entity, id, sync_token, request_id?}): voids an Invoice, SalesReceipt, BillPayment or Payment, zeroing its amounts but keeping the record.",
}

local exports: {[string]: any} = {
	getCompanyInfo = getCompanyInfo,
	getPreferences = getPreferences,
	query = query,
	getEntity = getEntity,
	getReport = getReport,
	getChanges = getChanges,
}
if config.access == "read-write" then
	exports.createEntity = createEntity
	exports.updateEntity = updateEntity
	exports.deleteEntity = deleteEntity
	exports.voidTransaction = voidTransaction
end

local WRITES = "Writes change the books immediately and are not undone by errors. Pass a unique request_id (up to 50 letters, digits or dashes) with each write: repeating a write with the same request_id returns the first result instead of creating a duplicate, so after a timeout or 5xx retry with the same request_id, or query before repeating a write sent without one. Creating an invoice does not email it."

exports.help = function(): string
	local list: {string} = {}
	for name in exports do if name ~= "help" then table.insert(list, name) end end
	table.sort(list)
	local lines = {
		"QuickBooks Online Accounting API (minorversion " .. MINOR_VERSION .. ")" .. (if config.environment == "production" then "" else " on Intuit's sandbox (test company)") .. ". A connection reaches one company, so no function takes a company or realm ID. Every function takes one named options object; entity and field names are QuickBooks' own PascalCase names. Connector calls return completed values: use them directly, without await.",
		"Examples: local company = qbo.getCompanyInfo(); local open = qbo.query({query=\"select * from Invoice where Balance > '0' maxresults 100\"}).items; local pnl = qbo.getReport({report='ProfitAndLoss', start_date='2026-01-01', end_date='2026-09-30', accounting_method='Accrual'}).",
		"Amounts are numbers in the company's home currency unless a record sets CurrencyRef. References are {value=id, name?}. Records carry Id, SyncToken and MetaData={CreateTime, LastUpdatedTime}.",
		"Errors report the HTTP status and QuickBooks' fault type, code, message and detail, such as 400 ValidationFault 6000 or 401 AUTHENTICATION 3200 (sign in again). QuickBooks allows about 500 requests per minute per company and 10 at a time.",
	}
	for _, name in list do table.insert(lines, about[name]) end
	table.insert(lines, if config.access == "read-write" then WRITES else "Read-only connections omit writes.")
	return table.concat(lines, "\n")
end

return exports
