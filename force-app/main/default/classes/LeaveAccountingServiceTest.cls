@IsTest
private class LeaveAccountingServiceTest {
    @TestSetup
    static void createFixtures() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Department__c department = new Department__c(Name = 'Accounting Test Department');
        insert department;

        for (String firstName : new List<String>{'AcctA', 'AcctB', 'AcctC', 'AcctD', 'AcctE', 'AcctF'}) {
            insert new Employee__c(
                First_Name__c = firstName,
                Last_Name__c = 'Test',
                Date_of_Birth__c = Date.newInstance(1985, 1, 1),
                Department__c = department.Id,
                Employment_Type__c = 'Full-Time',
                Gender__c = 'Other',
                Joining_Date__c = Date.today().addYears(-1),
                Salary__c = 50000,
                Status__c = 'Active'
            );
        }
        department.Head_of_Department__c = employeeId('AcctA');
        update department;
    }

    @IsTest
    static void validatesInclusiveDurationBoundaries() {
        LeaveAccountingService.validateRequestForTest(
            requestFor(employeeId('AcctA'), Date.newInstance(2026, 1, 1), Date.newInstance(2026, 1, 1))
        );
        LeaveAccountingService.validateRequestForTest(
            requestFor(employeeId('AcctA'), Date.newInstance(2026, 1, 1), Date.newInstance(2026, 12, 31))
        );
        assertValidationFailure(requestFor(
            employeeId('AcctA'), Date.newInstance(2026, 1, 1), Date.newInstance(2027, 1, 1)
        ));
        assertValidationFailure(requestFor(
            employeeId('AcctA'), null, Date.newInstance(2026, 1, 1)
        ));
        assertValidationFailure(requestFor(
            employeeId('AcctA'), Date.newInstance(2026, 1, 2), Date.newInstance(2026, 1, 1)
        ));
    }

    @IsTest
    static void provisionsOnlyPolicyBalancesAndRejectsDirectBalanceInsert() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id employee = employeeId('AcctA');
        Integer yearValue = Date.today().year();
        Boolean multipleEmployeesRejected = false;
        try {
            LeaveAccountingService.provisionBalances(
                new Set<Id>{employee, employeeId('AcctB')}
            );
        } catch (LeaveAccountingService.AccountingException expected) {
            multipleEmployeesRejected = true;
        }
        System.assert(
            multipleEmployeesRejected,
            'Synchronous provisioning must be limited to one employee.'
        );
        LeaveBalanceProvisioningAction.ProvisionRequest inputA =
            new LeaveBalanceProvisioningAction.ProvisionRequest();
        inputA.employeeId = employee;
        LeaveBalanceProvisioningAction.ProvisionRequest inputB =
            new LeaveBalanceProvisioningAction.ProvisionRequest();
        inputB.employeeId = employeeId('AcctB');
        Boolean bulkFlowRejected = false;
        try {
            LeaveBalanceProvisioningAction.provision(
                new List<LeaveBalanceProvisioningAction.ProvisionRequest>{inputA, inputB}
            );
        } catch (LeaveAccountingService.AccountingException expected) {
            bulkFlowRejected = true;
        }
        System.assert(bulkFlowRejected, 'Multi-employee Flow batches must fail closed.');

        Map<String, Leave_Policy__mdt> policiesByType = new Map<String, Leave_Policy__mdt>();
        for (Leave_Policy__mdt policy : Leave_Policy__mdt.getAll().values()) {
            policiesByType.put(policy.Leave_Type__c, policy);
        }
        List<Leave_Balance__c> balances = [
            SELECT Employee__c, Leave_Type__c, Leave_Year__c, Total_Leaves__c,
                   Used_Leaves__c, Leave_Balance_Key__c
            FROM Leave_Balance__c
            WHERE Employee__c = :employee AND Leave_Year__c = :yearValue
        ];
        System.assertEquals(policiesByType.size(), balances.size());
        for (Leave_Balance__c balance : balances) {
            System.assertEquals(policiesByType.get(balance.Leave_Type__c).Total_Leaves__c,
                balance.Total_Leaves__c);
            System.assertEquals(0, balance.Used_Leaves__c);
            System.assertEquals(
                expectedBalanceKey(employee, balance.Leave_Type__c, yearValue),
                balance.Leave_Balance_Key__c
            );
        }

        Leave_Balance__c unauthorized = new Leave_Balance__c(
            Employee__c = employee,
            Leave_Type__c = 'Paid',
            Leave_Year__c = yearValue + 1,
            Total_Leaves__c = 16,
            Used_Leaves__c = 0,
            Leave_Balance_Key__c = expectedBalanceKey(employee, 'Paid', yearValue + 1)
        );
        Database.SaveResult result = Database.insert(unauthorized, false);
        System.assertEquals(false, result.isSuccess(), 'Raw balance insertion must be denied.');
    }

    @IsTest
    static void auraEntryPointUsesThePermissionGatedService() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id requestId = LeaveAccountingEntryPoint.submitRequest(
            employeeId('AcctA'), testDate(5), testDate(5), 'Paid', 'Portfolio test'
        );
        Leave_Request__c created = requestRow(requestId);
        System.assertEquals('Pending', created.Status__c);
        System.assertEquals(true, created.Accounting_Cohort__c == 'Managed');
        System.assertEquals(employeeId('AcctA'), created.Approver__c);
        System.assertEquals(Date.today(), created.Applied_Date__c);
        System.assertEquals(null, created.Approval_Date__c);
    }

    @IsTest
    static void submissionRequiresAnAssignedApprover() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Department__c department = [
            SELECT Id, Head_of_Department__c
            FROM Department__c
            LIMIT 1
        ];
        department.Head_of_Department__c = null;
        update department;

        Integer requestCountBefore = [SELECT count() FROM Leave_Request__c];
        Boolean submissionRejected = false;
        try {
            submit(employeeId('AcctA'), testDate(5), testDate(5), 'Paid');
        } catch (LeaveAccountingService.AccountingException expected) {
            submissionRejected = true;
        }
        System.assert(submissionRejected, 'Submission without a manager or department head must fail.');
        System.assertEquals(requestCountBefore, [SELECT count() FROM Leave_Request__c]);
    }

    @IsTest
    static void unauthorizedOperationsAndProvisioningHaveNoEffects() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id employee = employeeId('AcctA');
        Id requestId = submit(employee, testDate(6), testDate(6), 'Paid');
        Integer requestCountBefore = [SELECT count() FROM Leave_Request__c WHERE Employee__c = :employee];
        Integer balanceCountBefore = [SELECT count() FROM Leave_Balance__c WHERE Employee__c = :employee];
        Decimal usedBefore = balanceRow(balanceForRequest(requestId)).Used_Leaves__c;
        Integer eventCountBefore = eventCount(requestId, null);

        Profile profile = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        User unauthorized = new User(
            Alias = 'noacct',
            Email = 'leave-test@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Unauthorized',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'leave-test-' + String.valueOf(Datetime.now().getTime()) + '@example.invalid'
        );
        insert unauthorized;

        LeaveAccountingService.skipPermissionCheckForTests = false;
        System.runAs(unauthorized) {
            System.assertEquals(
                false,
                FeatureManagement.checkPermission('Manage_Leave_Accounting'),
                'The test user must not inherit the accounting custom permission.'
            );
            for (String operation : new List<String>{
                'submit', 'provision', 'edit', 'approve', 'cancel', 'reject',
                'cancelPending', 'flowProvision'
            }) {
                System.assert(
                    expectUnauthorized(operation, employee, requestId),
                    operation + ' must be rejected for a user without Manage_Leave_Accounting.'
                );
            }
        }

        System.assertEquals(requestCountBefore,
            [SELECT count() FROM Leave_Request__c WHERE Employee__c = :employee]);
        System.assertEquals(balanceCountBefore,
            [SELECT count() FROM Leave_Balance__c WHERE Employee__c = :employee]);
        System.assertEquals(usedBefore, balanceRow(balanceForRequest(requestId)).Used_Leaves__c);
        System.assertEquals(eventCountBefore, eventCount(requestId, null));
        System.assertEquals('Pending', requestRow(requestId).Status__c);
    }

    @IsTest
    static void pendingEditValidatesChangesAndRejectsOverlaps() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id employee = employeeId('AcctB');
        submit(employee, testDate(101), testDate(102), 'Paid');
        Id requestId = submit(employee, testDate(105), testDate(106), 'Paid');

        Boolean overlapRejected = false;
        try {
            LeaveAccountingService.editPending(
                requestId, testDate(102), testDate(103), 'Sick', 'Changed leave reason'
            );
        } catch (LeaveAccountingService.AccountingException expected) {
            overlapRejected = true;
        }
        System.assert(overlapRejected, 'Editing into an inclusive overlap must fail.');
        System.assertEquals(testDate(105), requestRow(requestId).Start_Date__c);

        LeaveAccountingService.editPending(
            requestId, testDate(103), testDate(104), 'Sick', 'Changed leave reason'
        );
        Leave_Request__c edited = requestRow(requestId);
        System.assertEquals(testDate(103), edited.Start_Date__c);
        System.assertEquals(testDate(104), edited.End_Date__c);
        System.assertEquals('Sick', edited.Leave_Type__c);
    }

    @IsTest
    static void invalidPolicyConfigurationsFailClosed() {
        LeaveAccountingService.validatePoliciesForTest(validPolicyRows());
        assertPolicyFailure(new List<Leave_Policy__mdt>());
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12), policyRow('Sick', 10)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12), policyRow('Sick', 10),
            policyRow('Unpaid', 0), policyRow('Paid', 15)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12), policyRow('Sick', 10),
            policyRow('Unpaid', 1)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12), policyRow('Sick', 0),
            policyRow('Unpaid', 0)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12.5), policyRow('Sick', 10),
            policyRow('Unpaid', 0)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 1000), policyRow('Casual', 12), policyRow('Sick', 10),
            policyRow('Unpaid', 0)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12), policyRow('Sick', 10),
            policyRow('Unpaid', 0), policyRow('Volunteer', 1)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12), policyRow('Sick', 10),
            policyRow('Unpaid', 0), policyRow('Paid', -1)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', -1), policyRow('Casual', 12), policyRow('Sick', 10),
            policyRow('Unpaid', 0)
        });
        assertPolicyFailure(new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12), policyRow('Sick', 10),
            policyRow('Unpaid', null)
        });
    }

    @IsTest
    static void approvalDebitsExactlyAndCancellationRestoresExactlyOnce() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id employee = employeeId('AcctB');
        Id requestId = submit(employee, testDate(10), testDate(12), 'Paid');
        LeaveAccountingService.approve(requestId);

        Leave_Request__c approved = requestRow(requestId);
        Leave_Balance__c balance = balanceRow(approved.Active_Charged_Balance__c);
        System.assertEquals('Approved', approved.Status__c);
        System.assertEquals(Date.today(), approved.Approval_Date__c);
        System.assertEquals(3, approved.Active_Deducted_Days__c);
        System.assertEquals(3, balance.Used_Leaves__c);
        System.assertEquals(1, eventCount(requestId, 'Debit'));
        Leave_Accounting_Event__c debitEvent = [
            SELECT Id, Request__c, Balance__c, Cycle_Id__c, Cycle_Sequence__c,
                   Event_Type__c, Event_Key__c, Amount__c
            FROM Leave_Accounting_Event__c
            WHERE Request__c = :requestId AND Event_Type__c = 'Debit'
            LIMIT 1
        ];
        System.assertEquals(requestId, debitEvent.Request__c);
        System.assertEquals(balance.Id, debitEvent.Balance__c);
        System.assertEquals(approved.Active_Accounting_Cycle_Id__c, debitEvent.Cycle_Id__c);
        System.assertEquals(approved.Last_Accounting_Cycle_Sequence__c, debitEvent.Cycle_Sequence__c);
        System.assertEquals('Debit', debitEvent.Event_Type__c);
        System.assertEquals(approved.Active_Accounting_Cycle_Id__c + ':DEBIT', debitEvent.Event_Key__c);
        System.assertEquals(approved.Active_Deducted_Days__c, debitEvent.Amount__c);

        Boolean duplicateApprovalRejected = false;
        try {
            LeaveAccountingService.approve(requestId);
        } catch (LeaveAccountingService.AccountingException expected) {
            duplicateApprovalRejected = true;
        }
        System.assert(duplicateApprovalRejected, 'Repeated approval must not debit twice.');
        System.assertEquals(3, balanceRow(balance.Id).Used_Leaves__c);
        System.assertEquals(1, eventCount(requestId, 'Debit'));

        LeaveAccountingService.cancel(requestId);
        Leave_Request__c cancelled = requestRow(requestId);
        balance = balanceRow(balance.Id);
        System.assertEquals('Cancelled', cancelled.Status__c);
        System.assertEquals(null, cancelled.Active_Charged_Balance__c);
        System.assertEquals(null, cancelled.Active_Deducted_Days__c);
        System.assertEquals(null, cancelled.Active_Accounting_Cycle_Id__c);
        System.assertEquals(false, cancelled.Balance_Deducted__c);
        System.assertEquals(null, cancelled.Approval_Date__c);
        System.assertEquals(0, balance.Used_Leaves__c);
        System.assertEquals(1, eventCount(requestId, 'Restoration'));
        Leave_Accounting_Event__c restorationEvent = [
            SELECT Related_Debit_Event__c, Amount__c, Balance__c, Event_Key__c
            FROM Leave_Accounting_Event__c
            WHERE Request__c = :requestId AND Event_Type__c = 'Restoration'
            LIMIT 1
        ];
        System.assertEquals(debitEvent.Id, restorationEvent.Related_Debit_Event__c);
        System.assertEquals(debitEvent.Amount__c, restorationEvent.Amount__c);
        System.assertEquals(debitEvent.Balance__c, restorationEvent.Balance__c);
        System.assertEquals(approved.Active_Accounting_Cycle_Id__c + ':RESTORE',
            restorationEvent.Event_Key__c);

        Boolean duplicateRestoreRejected = false;
        try {
            LeaveAccountingService.cancel(requestId);
        } catch (LeaveAccountingService.AccountingException expected) {
            duplicateRestoreRejected = true;
        }
        System.assert(duplicateRestoreRejected, 'Repeated cancellation must not restore twice.');
        System.assertEquals(0, balanceRow(balance.Id).Used_Leaves__c);
        System.assertEquals(2, eventCount(requestId, null));
    }

    @IsTest
    static void pendingCancellationCanBeApprovedForTheFirstTime() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id requestId = submit(
            employeeId('AcctC'), testDate(20), testDate(21), 'Paid'
        );
        LeaveAccountingService.cancelPending(requestId);
        LeaveAccountingService.approve(requestId);

        Leave_Request__c approved = requestRow(requestId);
        System.assertEquals('Approved', approved.Status__c);
        System.assertEquals(true, approved.Ever_Approved__c);
        System.assertEquals(1, approved.Last_Accounting_Cycle_Sequence__c);
        System.assertEquals(1, eventCount(requestId, 'Debit'));
    }

    @IsTest
    static void cancelledApprovalStartsFreshCycleAndRejectedApprovalIsBlocked() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id employee = employeeId('AcctD');
        Id requestId = submit(employee, testDate(30), testDate(31), 'Paid');
        LeaveAccountingService.approve(requestId);
        LeaveAccountingService.cancel(requestId);
        LeaveAccountingService.approve(requestId);
        System.assertEquals(2, requestRow(requestId).Last_Accounting_Cycle_Sequence__c);
        System.assertEquals(2, eventCount(requestId, 'Debit'));

        Id rejectedId = submit(
            employeeId('AcctE'), testDate(40), testDate(41), 'Paid'
        );
        LeaveAccountingService.approve(rejectedId);
        LeaveAccountingService.reject(rejectedId);
        System.assertEquals(null, requestRow(rejectedId).Approval_Date__c);
        Decimal usedBeforeRetry = balanceRow(balanceForRequest(rejectedId)).Used_Leaves__c;
        Boolean rejectedRetry = false;
        try {
            LeaveAccountingService.approve(rejectedId);
        } catch (LeaveAccountingService.AccountingException expected) {
            rejectedRetry = true;
        }
        System.assert(rejectedRetry, 'Rejected requests must not be approved again.');
        System.assertEquals(usedBeforeRetry, balanceRow(balanceForRequest(rejectedId)).Used_Leaves__c);
        System.assertEquals(1, eventCount(rejectedId, 'Debit'));
        System.assertEquals(1, eventCount(rejectedId, 'Restoration'));
        Leave_Request__c rejected = requestRow(rejectedId);
        System.assertEquals(null, rejected.Active_Charged_Balance__c);
        System.assertEquals(null, rejected.Active_Deducted_Days__c);
        System.assertEquals(null, rejected.Active_Accounting_Cycle_Id__c);
        System.assertEquals(false, rejected.Balance_Deducted__c);
        System.assertEquals(0, balanceRow(balanceForRequest(rejectedId)).Used_Leaves__c);
        Leave_Accounting_Event__c rejectedDebit = [
            SELECT Id, Balance__c, Event_Key__c, Amount__c
            FROM Leave_Accounting_Event__c
            WHERE Request__c = :rejectedId AND Event_Type__c = 'Debit'
            LIMIT 1
        ];
        Leave_Accounting_Event__c rejectedRestoration = [
            SELECT Balance__c, Event_Key__c, Amount__c, Related_Debit_Event__c
            FROM Leave_Accounting_Event__c
            WHERE Request__c = :rejectedId AND Event_Type__c = 'Restoration'
            LIMIT 1
        ];
        System.assertEquals(rejectedDebit.Id, rejectedRestoration.Related_Debit_Event__c);
        System.assertEquals(rejectedDebit.Balance__c, rejectedRestoration.Balance__c);
        System.assertEquals(rejectedDebit.Amount__c, rejectedRestoration.Amount__c);
        System.assertEquals(String.valueOf(rejectedId) + ':1:DEBIT', rejectedDebit.Event_Key__c);
        System.assertEquals(String.valueOf(rejectedId) + ':1:RESTORE',
            rejectedRestoration.Event_Key__c);
    }

    @IsTest
    static void unpaidApprovalDoesNotCreateAccountingEvents() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id requestId = submit(
            employeeId('AcctF'), testDate(50), testDate(51), 'Unpaid'
        );
        LeaveAccountingService.approve(requestId);
        System.assertEquals(0, eventCount(requestId, null));
        System.assertEquals(null, requestRow(requestId).Active_Charged_Balance__c);
    }

    @IsTest
    static void overlapIsRejectedAndAdjacentDatesAreAllowed() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id employee = employeeId('AcctA');
        Id pendingId = submit(employee, testDate(60), testDate(62), 'Paid');
        Boolean overlapRejected = false;
        try {
            submit(employee, testDate(62), testDate(64), 'Sick');
        } catch (LeaveAccountingService.AccountingException expected) {
            overlapRejected = true;
        }
        System.assert(overlapRejected, 'An inclusive shared date must count as overlap.');
        LeaveAccountingService.approve(pendingId);
        Boolean approvedOverlapRejected = false;
        try {
            submit(employee, testDate(61), testDate(62), 'Sick');
        } catch (LeaveAccountingService.AccountingException expected) {
            approvedOverlapRejected = true;
        }
        System.assert(approvedOverlapRejected, 'Approved requests must also block overlaps.');
        submit(employee, testDate(63), testDate(64), 'Sick');
    }

    @IsTest
    static void insufficientBalanceFailsWithoutAccountingChanges() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id requestId = submit(
            employeeId('AcctD'), testDate(15), testDate(31), 'Paid'
        );
        assertApprovalFailure(requestId);
        System.assertEquals('Pending', requestRow(requestId).Status__c);
        System.assertEquals(0, eventCount(requestId, null));
        System.assertEquals(0, balanceRow(balanceForRequest(requestId)).Used_Leaves__c);
    }

    @IsTest
    static void missingDuplicateAndMalformedBalancesFailClosed() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id employee = employeeId('AcctB');
        Date futureStart = Date.newInstance(Date.today().year() + 2, 1, 5);
        Id missingBalanceRequest = submit(
            employee, futureStart, futureStart, 'Paid'
        );
        assertApprovalFailure(missingBalanceRequest);
        System.assertEquals(0, eventCount(missingBalanceRequest, null));

        Integer currentYear = Date.today().year();
        LeaveAccountingService.insertBalanceFixtureForTest(new Leave_Balance__c(
            Employee__c = employee,
            Leave_Type__c = 'Paid',
            Leave_Year__c = currentYear,
            Total_Leaves__c = 16,
            Used_Leaves__c = 0,
            Leave_Balance_Key__c = expectedBalanceKey(employee, 'Paid', currentYear) + '-duplicate'
        ));
        Id duplicateBalanceRequest = submit(
            employee, testDate(70), testDate(70), 'Paid'
        );
        assertApprovalFailure(duplicateBalanceRequest);
        System.assertEquals(0, eventCount(duplicateBalanceRequest, null));

        Date malformedYearDate = Date.newInstance(currentYear + 1, 2, 2);
        LeaveAccountingService.insertBalanceFixtureForTest(new Leave_Balance__c(
            Employee__c = employee,
            Leave_Type__c = 'Paid',
            Leave_Year__c = currentYear + 1,
            Total_Leaves__c = 16,
            Used_Leaves__c = 0,
            Leave_Balance_Key__c = 'incorrect-key'
        ));
        Id malformedBalanceRequest = submit(employee, malformedYearDate, malformedYearDate, 'Paid');
        assertApprovalFailure(malformedBalanceRequest);
        System.assertEquals(0, eventCount(malformedBalanceRequest, null));
    }

    @IsTest
    static void nullNumericBalanceValuesFailClosed() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Integer firstFutureYear = Date.today().year() + 3;
        Id missingTotalEmployee = employeeId('AcctC');
        LeaveAccountingService.insertBalanceFixtureForTest(new Leave_Balance__c(
            Employee__c = missingTotalEmployee,
            Leave_Type__c = 'Paid',
            Leave_Year__c = firstFutureYear,
            Total_Leaves__c = null,
            Used_Leaves__c = 0,
            Leave_Balance_Key__c = expectedBalanceKey(
                missingTotalEmployee, 'Paid', firstFutureYear
            )
        ));
        Date missingTotalDate = Date.newInstance(firstFutureYear, 1, 10);
        Id missingTotalRequest = submit(
            missingTotalEmployee, missingTotalDate, missingTotalDate, 'Paid'
        );
        assertApprovalFailure(missingTotalRequest);
        System.assertEquals(0, eventCount(missingTotalRequest, null));

        Integer secondFutureYear = firstFutureYear + 1;
        Id missingUsedEmployee = employeeId('AcctD');
        LeaveAccountingService.insertBalanceFixtureForTest(new Leave_Balance__c(
            Employee__c = missingUsedEmployee,
            Leave_Type__c = 'Paid',
            Leave_Year__c = secondFutureYear,
            Total_Leaves__c = 16,
            Used_Leaves__c = null,
            Leave_Balance_Key__c = expectedBalanceKey(
                missingUsedEmployee, 'Paid', secondFutureYear
            )
        ));
        Date missingUsedDate = Date.newInstance(secondFutureYear, 1, 10);
        Id missingUsedRequest = submit(
            missingUsedEmployee, missingUsedDate, missingUsedDate, 'Paid'
        );
        assertApprovalFailure(missingUsedRequest);
        System.assertEquals(0, eventCount(missingUsedRequest, null));
    }

    @IsTest
    static void directRequestAndLedgerWritesAreRejected() {
        Leave_Request__c request = new Leave_Request__c(
            Employee__c = employeeId('AcctF'),
            Start_Date__c = testDate(90),
            End_Date__c = testDate(90),
            Leave_Type__c = 'Paid',
            Status__c = 'Pending',
            Accounting_Cohort__c = 'Managed'
        );
        Database.SaveResult requestResult = Database.insert(request, false);
        System.assertEquals(false, requestResult.isSuccess());

        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id managedRequestId = submit(
            employeeId('AcctF'), testDate(95), testDate(95), 'Paid'
        );
        Leave_Accounting_Event__c eventRow = new Leave_Accounting_Event__c(
            Event_Key__c = 'fake-event',
            Event_Type__c = 'Debit',
            Cycle_Id__c = 'fake-cycle',
            Cycle_Sequence__c = 1,
            Request__c = managedRequestId,
            Balance__c = balanceForRequest(managedRequestId),
            Amount__c = 1,
            Occurred_At__c = System.now(),
            Actor__c = UserInfo.getUserId()
        );
        Database.SaveResult eventResult = Database.insert(eventRow, false);
        System.assertEquals(false, eventResult.isSuccess());

        Leave_Request__c directStatusChange = requestRow(managedRequestId);
        directStatusChange.Status__c = 'Approved';
        Database.SaveResult updateResult = Database.update(directStatusChange, false);
        System.assertEquals(false, updateResult.isSuccess(), 'Direct status changes must be denied.');

        Leave_Request__c directSnapshotChange = requestRow(managedRequestId);
        directSnapshotChange.Active_Charged_Balance__c = balanceForRequest(managedRequestId);
        directSnapshotChange.Active_Deducted_Days__c = 1;
        directSnapshotChange.Active_Accounting_Cycle_Id__c = String.valueOf(managedRequestId) + ':1';
        Database.SaveResult snapshotResult = Database.update(directSnapshotChange, false);
        System.assertEquals(false, snapshotResult.isSuccess(),
            'Accounting snapshots must not be directly changed.');

        Leave_Request__c directApproverChange = requestRow(managedRequestId);
        directApproverChange.Approver__c = employeeId('AcctB');
        Database.SaveResult approverResult = Database.update(directApproverChange, false);
        System.assertEquals(false, approverResult.isSuccess(), 'Approver changes must be denied.');

        Leave_Request__c directApprovalDateChange = requestRow(managedRequestId);
        directApprovalDateChange.Approval_Date__c = Date.today();
        Database.SaveResult approvalDateResult = Database.update(directApprovalDateChange, false);
        System.assertEquals(false, approvalDateResult.isSuccess(),
            'Approval date changes must be denied outside the service.');

        Leave_Request__c directAppliedDateChange = requestRow(managedRequestId);
        directAppliedDateChange.Applied_Date__c = Date.today().addDays(-1);
        Database.SaveResult appliedDateResult = Database.update(directAppliedDateChange, false);
        System.assertEquals(false, appliedDateResult.isSuccess(),
            'Application date changes must be denied outside the service.');

        LeaveAccountingService.approve(managedRequestId);
        Leave_Accounting_Event__c debit = [
            SELECT Id, Amount__c
            FROM Leave_Accounting_Event__c
            WHERE Request__c = :managedRequestId AND Event_Type__c = 'Debit'
            LIMIT 1
        ];
        debit.Amount__c = debit.Amount__c + 1;
        Database.SaveResult eventUpdateResult = Database.update(debit, false);
        System.assertEquals(false, eventUpdateResult.isSuccess(), 'Direct ledger updates must be denied.');
        Database.DeleteResult eventDeleteResult = Database.delete(debit, false);
        System.assertEquals(false, eventDeleteResult.isSuccess(), 'Direct ledger deletes must be denied.');

        Id employee = employeeId('AcctF');
        Integer currentYear = Date.today().year();
        Leave_Balance__c balance = [
            SELECT Id, Used_Leaves__c
            FROM Leave_Balance__c
            WHERE Employee__c = :employee
              AND Leave_Type__c = 'Paid'
              AND Leave_Year__c = :currentYear
            LIMIT 1
        ];
        balance.Used_Leaves__c = balance.Used_Leaves__c + 1;
        Database.SaveResult balanceUpdateResult = Database.update(balance, false);
        System.assertEquals(false, balanceUpdateResult.isSuccess(), 'Direct usage changes must be denied.');

        Database.DeleteResult requestDeleteResult = Database.delete(
            requestRow(managedRequestId), false
        );
        System.assertEquals(false, requestDeleteResult.isSuccess(), 'Request deletion must be denied.');
    }

    @IsTest
    static void requestAndLedgerUndeleteAreRejected() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id requestId = submit(employeeId('AcctC'), testDate(96), testDate(96), 'Paid');
        LeaveAccountingService.allowRequestDeletionForTests = true;
        Database.DeleteResult deleteResult;
        try {
            deleteResult = Database.delete(requestRow(requestId), false);
        } finally {
            LeaveAccountingService.allowRequestDeletionForTests = false;
        }
        System.assertEquals(true, deleteResult.isSuccess(), 'Test fixture must reach undelete path.');
        Database.UndeleteResult requestUndelete = Database.undelete(
            requestRowForUndelete(requestId), false
        );
        System.assertEquals(false, requestUndelete.isSuccess(), 'Request undelete must be denied.');

        Id approvedId = submit(employeeId('AcctD'), testDate(97), testDate(97), 'Paid');
        LeaveAccountingService.approve(approvedId);
        Leave_Accounting_Event__c debit = [
            SELECT Id, Request__c, Balance__c, Event_Key__c, Event_Type__c,
                   Cycle_Id__c, Cycle_Sequence__c, Amount__c, Occurred_At__c, Actor__c
            FROM Leave_Accounting_Event__c
            WHERE Request__c = :approvedId AND Event_Type__c = 'Debit'
            LIMIT 1
        ];
        LeaveAccountingService.allowEventMutationForTests = true;
        Database.DeleteResult eventDelete;
        try {
            eventDelete = Database.delete(debit, false);
        } finally {
            LeaveAccountingService.allowEventMutationForTests = false;
        }
        System.assertEquals(true, eventDelete.isSuccess(), 'Test fixture must reach event undelete path.');
        Database.UndeleteResult eventUndelete = Database.undelete(debit, false);
        System.assertEquals(false, eventUndelete.isSuccess(), 'Ledger event undelete must be denied.');
    }

    @IsTest
    static void approvalRollbackAfterRequestAndDebitEventWrites() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id requestId = submit(employeeId('AcctE'), testDate(98), testDate(98), 'Paid');
        Id balanceId = balanceForRequest(requestId);
        LeaveAccountingService.failAfterRequestUpdateForTests = true;
        Boolean failed = false;
        try {
            LeaveAccountingService.approve(requestId);
        } catch (LeaveAccountingService.AccountingException expected) {
            failed = true;
        } finally {
            LeaveAccountingService.failAfterRequestUpdateForTests = false;
        }
        System.assert(failed, 'Injected post-write failure must surface.');
        System.assertEquals('Pending', requestRow(requestId).Status__c);
        System.assertEquals(0, balanceRow(balanceId).Used_Leaves__c);
        System.assertEquals(0, eventCount(requestId, null));
    }

    @IsTest
    static void restorationAndRejectionRollbackAfterRequestAndEventWrites() {
        LeaveAccountingService.skipPermissionCheckForTests = true;
        Id cancelId = submit(employeeId('AcctF'), testDate(99), testDate(99), 'Paid');
        LeaveAccountingService.approve(cancelId);
        Id balanceId = balanceForRequest(cancelId);
        LeaveAccountingService.failAfterRequestUpdateForTests = true;
        Boolean cancelFailed = false;
        try {
            LeaveAccountingService.cancel(cancelId);
        } catch (LeaveAccountingService.AccountingException expected) {
            cancelFailed = true;
        } finally {
            LeaveAccountingService.failAfterRequestUpdateForTests = false;
        }
        System.assert(cancelFailed);
        System.assertEquals('Approved', requestRow(cancelId).Status__c);
        System.assertEquals(1, balanceRow(balanceId).Used_Leaves__c);
        System.assertEquals(1, eventCount(cancelId, 'Debit'));
        System.assertEquals(0, eventCount(cancelId, 'Restoration'));
        System.assertEquals(Date.today(), requestRow(cancelId).Approval_Date__c);

        Id rejectId = submit(employeeId('AcctE'), testDate(100), testDate(100), 'Paid');
        LeaveAccountingService.approve(rejectId);
        Id rejectBalanceId = balanceForRequest(rejectId);
        LeaveAccountingService.failAfterRequestUpdateForTests = true;
        Boolean rejectFailed = false;
        try {
            LeaveAccountingService.reject(rejectId);
        } catch (LeaveAccountingService.AccountingException expected) {
            rejectFailed = true;
        } finally {
            LeaveAccountingService.failAfterRequestUpdateForTests = false;
        }
        System.assert(rejectFailed);
        System.assertEquals('Approved', requestRow(rejectId).Status__c);
        System.assertEquals(1, balanceRow(rejectBalanceId).Used_Leaves__c);
        System.assertEquals(1, eventCount(rejectId, 'Debit'));
        System.assertEquals(0, eventCount(rejectId, 'Restoration'));
    }

    private static Id submit(Id employee, Date startDate, Date endDate, String leaveType) {
        String reason = leaveType == 'Sick' || leaveType == 'Unpaid' ? 'Test reason' : null;
        return LeaveAccountingService.submit(employee, startDate, endDate, leaveType, reason);
    }

    private static Leave_Request__c requestFor(Id employee, Date startDate, Date endDate) {
        return requestFor(employee, startDate, endDate, 'Paid');
    }

    private static Leave_Request__c requestFor(
        Id employee,
        Date startDate,
        Date endDate,
        String leaveType
    ) {
        return new Leave_Request__c(
            Employee__c = employee,
            Start_Date__c = startDate,
            End_Date__c = endDate,
            Leave_Type__c = leaveType,
            Status__c = 'Pending',
            Reason__c = leaveType == 'Sick' || leaveType == 'Unpaid' ? 'Test reason' : null
        );
    }

    private static List<Leave_Policy__mdt> validPolicyRows() {
        return new List<Leave_Policy__mdt>{
            policyRow('Paid', 16), policyRow('Casual', 12),
            policyRow('Sick', 10), policyRow('Unpaid', 0)
        };
    }

    private static Leave_Policy__mdt policyRow(String leaveType, Decimal allowance) {
        return new Leave_Policy__mdt(
            Leave_Type__c = leaveType,
            Total_Leaves__c = allowance
        );
    }

    private static void assertPolicyFailure(List<Leave_Policy__mdt> policies) {
        Boolean failed = false;
        try {
            LeaveAccountingService.validatePoliciesForTest(policies);
        } catch (LeaveAccountingService.AccountingException expected) {
            failed = true;
        }
        System.assert(failed, 'Invalid or incomplete policy configuration must fail closed.');
    }

    private static Boolean expectUnauthorized(String operation, Id employee, Id requestId) {
        try {
            if (operation == 'submit') {
                LeaveAccountingService.submit(employee, testDate(110), testDate(110), 'Paid', null);
            } else if (operation == 'provision') {
                LeaveAccountingService.provisionBalances(employee);
            } else if (operation == 'edit') {
                LeaveAccountingService.editPending(
                    requestId, testDate(111), testDate(111), 'Paid', null
                );
            } else if (operation == 'approve') {
                LeaveAccountingService.approve(requestId);
            } else if (operation == 'cancel') {
                LeaveAccountingService.cancel(requestId);
            } else if (operation == 'reject') {
                LeaveAccountingService.reject(requestId);
            } else if (operation == 'cancelPending') {
                LeaveAccountingService.cancelPending(requestId);
            } else if (operation == 'flowProvision') {
                LeaveBalanceProvisioningAction.ProvisionRequest flowInput =
                    new LeaveBalanceProvisioningAction.ProvisionRequest();
                flowInput.employeeId = employee;
                LeaveBalanceProvisioningAction.provision(
                    new List<LeaveBalanceProvisioningAction.ProvisionRequest>{flowInput}
                );
            }
        } catch (LeaveAccountingService.AccountingException expected) {
            return expected.getMessage().contains('not authorized');
        }
        return false;
    }

    private static void assertValidationFailure(Leave_Request__c request) {
        Boolean failed = false;
        try {
            LeaveAccountingService.validateRequestForTest(request);
        } catch (LeaveAccountingService.AccountingException expected) {
            failed = true;
        }
        System.assert(failed, 'Invalid request dates must fail validation.');
    }

    private static void assertApprovalFailure(Id requestId) {
        Boolean failed = false;
        try {
            LeaveAccountingService.approve(requestId);
        } catch (LeaveAccountingService.AccountingException expected) {
            failed = true;
        }
        System.assert(failed, 'Inconsistent balance state must fail approval.');
    }

    private static Id employeeId(String firstName) {
        return [
            SELECT Id
            FROM Employee__c
            WHERE First_Name__c = :firstName
            LIMIT 1
        ].Id;
    }

    private static Leave_Request__c requestRow(Id requestId) {
        return [
            SELECT Id, Status__c, Accounting_Cohort__c, Ever_Approved__c, Balance_Deducted__c,
                   Active_Charged_Balance__c, Active_Deducted_Days__c,
                   Active_Accounting_Cycle_Id__c, Last_Accounting_Cycle_Sequence__c,
                   Start_Date__c, End_Date__c, Applied_Date__c, Leave_Type__c,
                   Approver__c, Approval_Date__c
            FROM Leave_Request__c
            WHERE Id = :requestId
        ];
    }

    private static Leave_Request__c requestRowForUndelete(Id requestId) {
        return [
            SELECT Id
            FROM Leave_Request__c
            WHERE Id = :requestId ALL ROWS
        ];
    }

    private static Id balanceForRequest(Id requestId) {
        Leave_Request__c request = [
            SELECT Employee__c, Active_Charged_Balance__c
            FROM Leave_Request__c
            WHERE Id = :requestId
        ];
        if (request.Active_Charged_Balance__c != null) {
            return request.Active_Charged_Balance__c;
        }
        Integer currentYear = Date.today().year();
        return [
            SELECT Id
            FROM Leave_Balance__c
            WHERE Employee__c = :request.Employee__c
              AND Leave_Type__c = 'Paid'
              AND Leave_Year__c = :currentYear
            LIMIT 1
        ].Id;
    }

    private static Leave_Balance__c balanceRow(Id balanceId) {
        return [
            SELECT Id, Used_Leaves__c
            FROM Leave_Balance__c
            WHERE Id = :balanceId
        ];
    }

    private static Integer eventCount(Id requestId, String eventType) {
        if (eventType == null) {
            return [SELECT count() FROM Leave_Accounting_Event__c WHERE Request__c = :requestId];
        }
        return [
            SELECT count()
            FROM Leave_Accounting_Event__c
            WHERE Request__c = :requestId AND Event_Type__c = :eventType
        ];
    }

    private static String expectedBalanceKey(Id employee, String leaveType, Integer yearValue) {
        return String.valueOf(employee) + '-' + leaveType + '-' + String.valueOf(yearValue);
    }

    private static Date testDate(Integer daysAfterStartOfYear) {
        return Date.newInstance(Date.today().year(), 1, 1).addDays(daysAfterStartOfYear);
    }
}
