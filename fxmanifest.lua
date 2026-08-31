-- Resource Metadata
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'DRS'
description 'DRS Garages - multi-framework vehicle garage system'
version '2.6.0-drs.1'

dependencies {
    'ox_lib',
    'oxmysql',
    '/onesync'
}

ui_page 'html/index.html'

files {
    'locales/*.json',
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'html/assets/*.svg'
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
    'server/*.lua'
}
