metadata description = '''
Assertions about the naming functions, evaluated offline.

An assert is a compile-time claim about an expression. These run without a subscription,
without credentials and without deploying anything, which makes them the only tests in an
IaC repository that can run on every commit in under a second.
'''

import { regionCode, resourceName, globalName, dnsLabel } from '../naming.bicep'

param location string
param workload string
param environment string
param seed string

assert regionIsMapped = regionCode(location) == 'weu'

assert unknownRegionDegrades = regionCode('antarcticacentral') == 'ant'

assert hyphenatedNameShape = resourceName('rg', workload, 'network', environment, location) == 'rg-ztwp-network-dev-weu'

assert emptyPurposeDropsSegment = resourceName('app', workload, '', environment, location) == 'app-ztwp-dev-weu'

// Storage accounts reject anything over 24 characters and anything that is not lowercase
// alphanumeric. This is the assertion that catches a naming change before Azure does.
assert globalNameFitsStorageLimit = length(globalName('st', workload, environment, seed)) <= 24

assert dnsLabelIsLowercase = dnsLabel(workload, environment, seed) == toLower(dnsLabel(workload, environment, seed))
