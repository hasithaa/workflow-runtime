import ballerina/workflow;

# Processes one expense claim with two manager reviews: first the request check
# (ask for the supporting bills, or reject), then — once the employee submits the
# bills as a data event — the bill review that decides the reimbursement. The
# payment carries a Human Review retry policy (gateway rejections become a manager
# retry review) and notifications carry an Auto Retry policy.
#
# + ctx - The workflow context
# + claim - The submitted claim
# + dataEvents - Futures for the data events this workflow waits on
# + return - The final outcome, or an error
@workflow:Workflow
function expenseApprovalWorkflow(workflow:Context ctx, ExpenseClaim claim,
        record {|future<BillSubmission> billSubmitted;|} dataEvents) returns ExpenseResult|error {
    boolean valid = check ctx->callActivity(validateClaim, {"claim": claim});
    if !valid {
        return {claimId: claim.claimId, status: "INVALID"};
    } else {
        // Managers decide; the expense administrator sees every task and may reassign, re-deadline or decide it.
        RequestDecision request = check ctx->awaitHumanTask("checkExpenseRequest",
                {"claimId": claim.claimId, "employee": claim.employee,
                    "amount": claim.amount, "purpose": claim.purpose},
                userRoles = "manager", administratorRoles = "expense-admin",
                title = string `Check expense request ${claim.claimId}`,
                description = "Review the new claim: REQUEST_BILL - request the supporting bills, or REJECT - reject it.",
                timeout = {days: 3});
        if request.action == REJECT {
            string _ = check ctx->callActivity(notifyEmployee,
                    {"claimId": claim.claimId, "message": string `Claim rejected: ${request.comment}`},
                    retryPolicy = {maxRetries: 3, retryDelay: 2});
            return {claimId: claim.claimId, status: "REJECTED"};
        } else {
            string _ = check ctx->callActivity(notifyEmployee,
                    {"claimId": claim.claimId, "message": "Please submit the supporting bills for your claim."},
                    retryPolicy = {maxRetries: 3, retryDelay: 2});
            BillSubmission submission = check wait dataEvents.billSubmitted;
            boolean billsValid = check ctx->callActivity(validateBills,
                    {"claim": claim, "submission": submission});

            ApprovalDecision decision = check ctx->awaitHumanTask("reviewBills",
                    {"claimId": claim.claimId, "amount": claim.amount,
                        "billCount": submission.bills.length(), "billsMatchClaim": billsValid},
                    userRoles = "manager", administratorRoles = "expense-admin",
                    title = string `Review bills for claim ${claim.claimId}`,
                    description = "Verify the submitted bills and approve or reject the reimbursement.",
                    timeout = {days: 3});
            if decision.approved {
                string paymentRef = check ctx->callActivity(makePayment,
                        {"claimId": claim.claimId, "amount": claim.amount, "currency": claim.currency},
                        retryPolicy = {userRoles: "manager", administratorRoles: "expense-admin"});
                string _ = check ctx->callActivity(notifyEmployee,
                        {"claimId": claim.claimId, "message": string `Claim approved and paid: ${paymentRef}`},
                        retryPolicy = {maxRetries: 3, retryDelay: 2});
                return {claimId: claim.claimId, status: "APPROVED", paymentRef};
            } else {
                string _ = check ctx->callActivity(notifyEmployee,
                        {"claimId": claim.claimId, "message": string `Claim rejected: ${decision.comment}`},
                        retryPolicy = {maxRetries: 3, retryDelay: 2});
                return {claimId: claim.claimId, status: "REJECTED"};
            }
        }
    }
}
