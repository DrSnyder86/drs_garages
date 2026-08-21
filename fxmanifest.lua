-- Resource Metadata
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'DRS; based on Lunar Scripts lunar_garage'
description 'DRS Garages - multi-framework vehicle garage system'
version '2.1.0-drs.1'

files {
    'locales/*.json'
}

shared_scripts {
    '@ox_lib/init.lua',
    'config/config.lua'
}

client_scripts {
    'framework/**/client.lua',
    'client/framework/*.lua',
    'utils/cl_main.lua',
    'config/cl_edit.lua',
    'client/*.lua'
}

server_scripts {
    'framework/**/server.lua',
    '@oxmysql/lib/MySQL.lua',
    'server/framework/*.lua',
    'utils/sv_main.lua',
    'config/sv_config.lua',
    'utils/sv_database.lua',
    'locales/*.lua',
    'server/*.lua'
}
