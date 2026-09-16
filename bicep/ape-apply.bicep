// Applies the quota writes a placement decision asked for.
//
// The Bicep half of the Bicep path. Bicep cannot read quota state -- see
// docs/decisions/0001 -- so the reading and the deciding happen in
// powershell/ApePlacement.psm1, which emits a .bicepparam for this file.
//
// `limit` is absolute, never a delta, which is what lets a quota be expressed
// declaratively at all.

targetScope = 'subscription'

@description('Azure region the quota applies to, e.g. eastus.')
param region string

@description('''
Straight from the decision's `writes_required`: a list of
{ scope: 'regional' | 'family', name: string, limit: int }.

Empty means the decision needs nothing written, and this template deploys
nothing. Each `limit` is the ABSOLUTE new value.
''')
param writesRequired array = []

// Microsoft.Quota/quotas is an extension resource. Its scope is the Compute
// location, which is why this needs a symbolic reference rather than a plain
// resource ID.
resource computeLocation 'Microsoft.Compute/locations@2021-07-01' existing = {
  name: region
}

var regionalWrites = filter(writesRequired, w => w.scope == 'regional')
var familyWrites = filter(writesRequired, w => w.scope == 'family')

// The regional vCPU cap first. A family limit above it is unusable, so raising
// the family without raising the cap buys nothing.
resource regionalQuota 'Microsoft.Quota/quotas@2025-09-01' = [
  for w in regionalWrites: {
    scope: computeLocation
    name: w.name
    properties: {
      name: {
        value: w.name
      }
      limit: {
        limitObjectType: 'LimitValue'
        value: w.limit
      }
    }
  }
]

resource familyQuota 'Microsoft.Quota/quotas@2025-09-01' = [
  for w in familyWrites: {
    scope: computeLocation
    name: w.name
    properties: {
      name: {
        value: w.name
      }
      limit: {
        limitObjectType: 'LimitValue'
        value: w.limit
      }
    }
    dependsOn: [
      regionalQuota
    ]
  }
]

@description('What was written, with the limit Azure reported back.')
output applied array = [
  for (w, i) in writesRequired: {
    scope: w.scope
    name: w.name
    requested: w.limit
  }
]

@description('Whether anything was written at all.')
output writeCount int = length(writesRequired)
