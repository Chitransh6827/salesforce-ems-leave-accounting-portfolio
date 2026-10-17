trigger LeaveAccountingEventTrigger on Leave_Accounting_Event__c (before insert, before update, before delete, after undelete) {
    if (Trigger.isInsert) {
        LeaveAccountingService.guardEventInsert(Trigger.new);
    } else if (Trigger.isUndelete) {
        LeaveAccountingService.guardEventMutation(Trigger.new);
    } else {
        LeaveAccountingService.guardEventMutation(Trigger.old);
    }
}
