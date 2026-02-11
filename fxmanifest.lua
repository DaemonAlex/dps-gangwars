fx_version 'cerulean'
games { 'gta5' }
lua54 'yes'

name 'gang-ambient-ai'
author 'DaemonAlex'
description 'Gang ambient AI system - augments rcore_gangs with intelligent NPCs, territory population, and war reinforcements'
version '2.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'bridge/init.lua',
    'bridge/rcore_gangs.lua',
    'bridge/standalone.lua'
}

client_script 'client.lua'
server_script 'server.lua'

dependencies {
    'ox_lib',
    'qb-core'
}
