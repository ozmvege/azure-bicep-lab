metadata description = '''
The test entry point. Run it with:

  bicep test infra/tests/main.tests.bicep

Each test block points at a file full of asserts and supplies its parameters. The test
framework and asserts are both experimental features and are switched on in bicepconfig.json;
that is the trade for having any offline test at all.
'''

test namingConventions 'naming-assertions.bicep' = {
  params: {
    location: 'westeurope'
    workload: 'ztwp'
    environment: 'dev'
    seed: '/subscriptions/00000000-0000-0000-0000-000000000000'
  }
}
