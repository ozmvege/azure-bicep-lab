metadata description = '''
Naming convention as code.

Azure resource names are not a style question: storage accounts and key vaults are globally
unique, some types forbid hyphens, and a name chosen by hand in the portal is a name nobody
can reproduce. These functions encode the Cloud Adoption Framework abbreviations once, so
every module derives its names the same way from the same inputs.

User-defined functions cannot read variables or call runtime functions such as
resourceGroup() or reference(), which is why the uniqueness seed is passed in rather than
read from the deployment context.
'''

@export()
@description('''
Three-letter region code. Falls back to the first three letters of the region name for any
region not in the table, so an unlisted region degrades instead of failing.
''')
func regionCode(location string) string => {
  westeurope: 'weu'
  northeurope: 'neu'
  germanywestcentral: 'gwc'
  germanynorth: 'gn'
  switzerlandnorth: 'chn'
  swedencentral: 'sdc'
  francecentral: 'frc'
  uksouth: 'uks'
  ukwest: 'ukw'
  eastus: 'eus'
  eastus2: 'eus2'
  westus2: 'wus2'
  centralus: 'cus'
}[?toLower(replace(location, ' ', ''))] ?? substring(toLower(replace(location, ' ', '')), 0, 3)

@export()
@description('Hyphenated name: <abbreviation>-<workload>-<purpose>-<environment>-<region>.')
func resourceName(abbreviation string, workload string, purpose string, environment string, location string) string =>
  toLower(empty(purpose)
    ? '${abbreviation}-${workload}-${environment}-${regionCode(location)}'
    : '${abbreviation}-${workload}-${purpose}-${environment}-${regionCode(location)}')

@export()
@description('''
Name for the resource types that allow no hyphens and demand global uniqueness — storage
accounts, key vaults, container registries. The seed should be something stable and
subscription-specific so two people running this lab do not collide.

take() rather than substring(). substring throws when the string is shorter than the
requested length, and with a short workload name this one is: st + ztwp + dev + a 13
character uniqueString is 22 characters, and substring(…, 0, 23) fails on it. The offline
assertion in tests/naming-assertions.bicep is what caught that — see docs/11-testing.md.
''')
func globalName(abbreviation string, workload string, environment string, seed string) string =>
  toLower(take('${abbreviation}${workload}${environment}${uniqueString(seed)}', 24))

@export()
@description('Public DNS label for the gateway public IP. Must be unique within the region.')
func dnsLabel(workload string, environment string, seed string) string =>
  toLower('${workload}-${environment}-${substring(uniqueString(seed), 0, 6)}')
