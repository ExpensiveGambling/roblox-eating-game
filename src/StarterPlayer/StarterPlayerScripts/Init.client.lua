-- Init.client.lua
-- Boot sequence: requires and starts every client Controller.

local Controllers = script.Parent.Controllers

local CurrencyHUDController = require(Controllers.CurrencyHUDController)

CurrencyHUDController.Start()
