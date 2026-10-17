trigger EmployeeTrigger on Employee__c (before insert, before update) {
    for (Employee__c emp : Trigger.new) {

        if (String.isBlank(emp.Designation__c)) {
            emp.Designation__c = 'Unkown';
        }

    }
}