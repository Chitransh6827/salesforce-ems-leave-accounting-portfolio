public with sharing class LeaveAccountingEntryPoint {
    @AuraEnabled
    public static Id submitRequest(
        Id employeeId,
        Date startDate,
        Date endDate,
        String leaveType,
        String reason
    ) {
        return LeaveAccountingService.submit(employeeId, startDate, endDate, leaveType, reason);
    }

    @AuraEnabled
    public static void editPendingRequest(
        Id requestId,
        Date startDate,
        Date endDate,
        String leaveType,
        String reason
    ) {
        LeaveAccountingService.editPending(requestId, startDate, endDate, leaveType, reason);
    }

    @AuraEnabled
    public static void approveRequest(Id requestId) {
        LeaveAccountingService.approve(requestId);
    }

    @AuraEnabled
    public static void cancelRequest(Id requestId) {
        LeaveAccountingService.cancel(requestId);
    }

    @AuraEnabled
    public static void rejectRequest(Id requestId) {
        LeaveAccountingService.reject(requestId);
    }

    @AuraEnabled
    public static void cancelPendingRequest(Id requestId) {
        LeaveAccountingService.cancelPending(requestId);
    }
}
