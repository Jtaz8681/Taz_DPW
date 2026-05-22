fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'Taz DPW - Department of Public Works Job Script'
author 'Taz'
version '1.0.0'

shared_scripts {
    '@ox_lib/import.lua',
    'config.lua',
}

client_scripts {
    'client/utils.lua',
    'client/main.lua',
    'client/tasks.lua',
}

server_scripts {
    'server/server.lua',
}

dependencies {
    'ox_lib',
}

files {
    'game_references/**/*',
}