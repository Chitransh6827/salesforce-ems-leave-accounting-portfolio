public with sharing class LeaveBalanceProvisioningAction {
    public class ProvisionRequest {
        @InvocableVariable(required=true)
        public Id employeeId;
    }

    @InvocableMethod(
        label='Provision Employee Leave Balances'
        description='Creates current-year leave balances from Leave Policy metadata.'
    )
    public static void provision(List<ProvisionRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            throw new LeaveAccountingService.AccountingException(
                'At least one employee is required for balance provisioning.'
            );
        }
        Set<Id> employeeIds = new Set<Id>();
        for (ProvisionRequest request : requests) {
            if (request == null || request.employeeId == null ||
                employeeIds.contains(request.employeeId)) {
                throw new LeaveAccountingService.AccountingException(
                    'Provisioning input contains a missing or duplicate employee.'
                );
            }
            employeeIds.add(request.employeeId);
        }
        LeaveAccountingService.provisionBalances(employeeIds);
    }
}
