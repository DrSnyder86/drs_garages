RegisterNetEvent('drs_garages:client:doctorReport', function(report)
    if type(report) ~= 'table' or type(report.entries) ~= 'table' or type(report.summary) ~= 'table' then return end

    print('[drs_garages][doctor] DRS Garages diagnostic report')

    for _, entry in ipairs(report.entries) do
        if type(entry) == 'table' then
            print(('[drs_garages][doctor][%s] %s: %s'):format(
                tostring(entry.level or 'WARN'),
                tostring(entry.check or 'Check'),
                tostring(entry.detail or '')
            ))
        end
    end

    local passed = tonumber(report.summary.PASS) or 0
    local warnings = tonumber(report.summary.WARN) or 0
    local failures = tonumber(report.summary.FAIL) or 0
    local message = ('Doctor finished: %d passed, %d warning(s), %d failure(s). Details were written to your F8 console.'):format(
        passed,
        warnings,
        failures
    )
    local notificationType = failures > 0 and 'error' or warnings > 0 and 'warning' or 'success'

    if type(ShowNotification) == 'function' then
        ShowNotification(message, notificationType)
    else
        lib.notify({
            title = 'DRS Garages Doctor',
            description = message,
            type = notificationType,
            position = 'bottom'
        })
    end
end)

