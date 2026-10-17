trigger LeaveBalanceTrigger on Leave_Balance__c (before insert, before update, before delete, after undelete) {
    if (Trigger.isInsert) {
        LeaveAccountingService.guardBalanceInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        LeaveAccountingService.guardBalanceUpdate(Trigger.new, Trigger.oldMap);
    } else if (Trigger.isDelete) {
        LeaveAccountingService.guardBalanceDelete(Trigger.old);
    } else if (Trigger.isUndelete) {
        LeaveAccountingService.guardBalanceDelete(Trigger.new);
    }
}
