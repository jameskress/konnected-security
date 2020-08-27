local module = ...

local log = require("log")

-- print HTTP status line
local function printHttpResponse(code, data)
  local a = { "Heap:", node.heap(), "HTTP Call:", code }
  for k, v in pairs(data) do
    table.insert(a, k)
    table.insert(a, v)
  end
  log.info(unpack(a))
end


-- This loop makes the HTTP requests to the home automation service to get or update device state
local function startLoop(settings)
  local dni = wifi.sta.getmac():gsub("%:", "")

  local timeout = tmr.create()
  timeout:register(10000, tmr.ALARM_SEMI, node.restart)

  local sendTimer = tmr.create()
  sendTimer:alarm(200, tmr.ALARM_AUTO, function(t)

    -- gets state of actuators
    if actuatorGet[1] then
      t:stop()
      local actuator = actuatorGet[1]
      timeout:start()

      http.get(table.concat({ settings.endpoint, "/device/", dni, '?pin=', actuator.pin }),
        table.concat({ "Authorization: Bearer ", settings.token, "\r\nAccept: application/json\r\n" }),
        function(code, response)
          timeout:stop()
          local pin, state, json_response, status
          if response and code >= 200 and code < 300 then
            status, json_response = pcall(function() return sjson.decode(response) end)
            if status then
              pin = tonumber(json_response.pin)
              state = tonumber(json_response.state)
            end
          end
          printHttpResponse(code, {pin = pin, state = state})

          gpio.mode(actuator.pin, gpio.OUTPUT)
          if pin == actuator.pin and code >= 200 and code < 300 and state then
            gpio.write(actuator.pin, state)
          else
            state = actuator.trigger == gpio.LOW and gpio.HIGH or gpio.LOW
            gpio.write(actuator.pin, state)
          end
          log.info("Initialized actuator Pin:", actuator.pin, "Trigger:", actuator.trigger, "Initial state:", state)

          table.remove(actuatorGet, 1)
          blinktimer:start()
          t:start()
        end)

      -- update state of sensors when needed
    elseif sensorPut[1] then
      t:stop()
      local sensor = sensorPut[1]
      printHttpResponse(0, sensor)
      timeout:start()
      http.put(table.concat({ settings.endpoint, "/device/", dni }),
        table.concat({ "Authorization: Bearer ", settings.token, "\r\nAccept: application/json\r\nContent-Type: application/json\r\n" }),
        sjson.encode(sensor),
        function(code)
          timeout:stop()
          printHttpResponse(code, sensor)

          -- check for success and retry if necessary
          if code >= 200 and code < 300 then
            table.remove(sensorPut, 1)
          else
            -- retry up to 10 times then reboot as a failsafe
            local retry = sensor.retry or 0
            if retry == 10 then
              log.error("Retried 10 times and failed. Rebooting in 30 seconds.")
              for k, v in pairs(sensorPut) do sensorPut[k] = nil end -- remove all pending sensor updates
              tmr.create():alarm(30000, tmr.ALARM_SINGLE, function() node.restart() end) -- reboot in 30 sec
            else
              sensor.retry = retry + 1
              sensorPut[1] = sensor
            end
          end

          blinktimer:start()
          t:start()
        end)
    end

    collectgarbage()
  end)
  log.info("REST Endpoint:", settings.endpoint)
end

return function(settings)
  package.loaded[module] = nil
  module = nil
  return startLoop(settings)
end