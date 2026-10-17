trigger LeaveRequestTrigger on Leave_Request__c (before insert, before update, before delete, after undelete) {
    if (Trigger.isInsert) {
        LeaveAccountingService.guardBeforeInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        LeaveAccountingService.guardBeforeUpdate(Trigger.new, Trigger.oldMap);
    } else if (Trigger.isDelete) {
        LeaveAccountingService.guardRequestDelete(Trigger.old);
    } else if (Trigger.isUndelete) {
        LeaveAccountingService.guardRequestDelete(Trigger.new);
    }
}
