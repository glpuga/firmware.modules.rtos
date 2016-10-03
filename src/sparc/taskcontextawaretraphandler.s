/* Copyright 2016, Gerardo Puga (UNLP)
 *
 * This file is part of CIAA Firmware.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products derived from this
 *    software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

/** \brief SPARC V8 Context Aware Trap Service Routine Handler
 **
 ** \file sparc/trapwindowoveflowhandler.s
 ** \arch sparc
 **/

/** \addtogroup FreeOSEK
 ** @{ */
/** \addtogroup FreeOSEK_Os
 ** @{ */
/** \addtogroup FreeOSEK_Os_Internal
 ** @{ */

   !
   ! This is the code that sets the everything up before actually executing the user's trap
   ! service routines, including task context management.
   !
   ! The code assumes the following register arrangement on entry:
   !  %l0 = psr
   !  %l1 = PC
   !  %l2 = nPC
   !  %l3 = hardware/software trap handler table index. The sixth bit is 0 for interrupts and 1 for sofware traps.
   !
   ! And performs the following actions:
   ! * Checks whether this interrupt/software trap is the outermost one, or whether it is executing as a
   !   nested interrupt/software trap:
   !
   ! > If it is the outermost, it:
   !   * Sets the interrupt context global variable to 1.
   !   * Dumps all of the thread's in-use register windows (not the trap window) to the stack.
   !   * Saves the interrupted thread's context to the thread's stack too.
   !   * Saves the final stack pointer to the current_task_context global variable.
   !   * Optional: replace the application stack for a dedicated interrupt stack.
   !   * Fetch the actual trap service routine start address from the ISR table.
   !   * CHECK: [Disables any further interrupts by setting the PIL to 15]
   !   * Enable traps.
   !   * Call the trap service routine.
   !   * Disable traps.
   !   * CHECK: [Set the PIL to 0 again]
   !   * Set the interrupt context flag to 0.
   !   * Recover current_task_context and uses it to setup the thread stack pointer.
   !   * Recover the interrupted thread's context from the stack.
   !   * Return from trap.
   !
   ! > If nested, it:
   !   * Makes sure that there's at least one register window available for further traps.
   !   * Saves the interrupted trap's context data to the stack.
   !   * Fetch the actual trap service routine start address from the ISR table.
   !   * CHECK: [Disables any further interrupts by setting the PIL to 15]
   !   * Enable traps.
   !   * Call the trap service routine.
   !   * Disable traps.
   !   * CHECK: [Set the PIL to 0 again]
   !   * Recover the interrupted trap's context from the stack.
   !   * Return from trap.
   !
   ! Whenever thread/trap context is mentioned, the following items are considered relevant
   ! context data:
   !   * global registers (%g1 to %g7)
   !   * in registers (%i0 to %i7)
   !   * Y register.
   !   * PSR register.
   !   * PC and nPC
   !   * [FOR THREADS ONLY] Floating point state data, if enabled: FSR register and %f0 to %f31.
   !

   .global sparcTaskContextAwareTrapHandler
   .type   sparcTaskContextAwareTrapHandler, #function

   .extern system_in_interrupt_context
   .extern detected_sparc_register_windows
   .extern active_thread_context_stack_pointer

   .extern sparcInterruptHandlerCaller
   .extern sparcTaskContextReplacementHandlerCaller

sparcTaskContextAwareTrapHandler:

   !
   ! Check whether we are already in interrupt/trap context (i.e. in a nested trap) or whether
   ! this is the outermost interrupt/trap.

   ! Load the current value of the flag
   sethi   %hi(system_in_interrupt_context), %l4
   ld      [%lo(system_in_interrupt_context) + %l4], %l5

   ! Prepare the value to load in the flag variable
   mov     0x1, %l6

   ! Test whether the old value was zero
   tst     %l5
   bnz     nested_interrupt_handler

   ! Update the value of the flag in memory (this happens in the delay slot of the branch,
   ! whatever the result of the test turns out to be)
   st      %l6, [%lo(system_in_interrupt_context) + %l4]

outermost_trap_handler:

   ! ****************************************************
   !
   ! Save all of the in-use register windows except the trap window to the stack.
   !

   ! At this point there are three different types of window registers within the register window
   ! set:
   ! * Windows that are in use by the interrupted task.
   ! * The invalid window.
   ! * Unused windows, that do not belong to either sets one or two.
   ! It is important to note in the following explanation the trap window is not considered "in-use"
   ! by the interrupted thread since it is not part of the thread's state. Therefore the
   ! trap window belongs to groups either two (if there are no unused windows) or three (if there are).
   !
   ! The in-use windows are located between the invalid window and the trap window when moving from the former
   ! to the later in descending numbering direction (SAVE instruction movement direction). The unused windows
   ! are between the trap window (including it) and the invalid window. If the trap window overlaps the
   ! invalid window, the unused windows set is empty. See the diagram on the "The SPARC Architecture Manual
   ! Version 8", chapter 4.
   !
   ! At this point there are:
   ! * At least one register window in the in-use set (since there was an active register window
   !   when the trap was generated.
   ! * One invalid window.
   ! * Between NWINDOWS-2 and 0 windows in the unused set.
   !
   ! The following code must:
   ! * Walk through all of the register windows in the in-use set, saving their contents to the stack as it goes.
   ! * Set the window inmediately above the trap window as the new invalid window.
   !
   ! After having saved all of the in-use windows to the stack, the state of the register windows set is
   ! going to be:
   ! * Zero in-use windows. A window underflow trap will be generated by the RETT instruction when we exit
   !   this trap.
   ! * One invalid window, located inmediately above the trap window.
   ! * NWINDOWS-1 windows in the unused set.
   ! The trap window will be located on the first unused window (remember, "unused" means that it is not in use by
   ! the interrupted thread, not the trap)

   ! Since we will need to be walking around the register window set quite a bit, we'll need
   ! to use global registers to store our work variables. In order to do that we must
   ! first back their values up somewhere else.
   mov     %g4, %l4
   mov     %g5, %l5
   mov     %g6, %l6
   mov     %g7, %l7

   !
   ! Determine the WIM field bit mask from the number of register windows
   sethi   %hi(detected_sparc_register_windows), %g7
   ld      [%lo(detected_sparc_register_windows) + %g7], %g7
   ! The number of implemented register windows is always a power of 2, therefore the following
   ! sentence calculates the bit mask.
   sub     %g7, 0x1, %g7

   !
   ! Isolate the CWP field of the PSR register and use it to determine the mask associated to the
   ! window inmediately above the trap window
   and     %l0, SPARC_PSR_CWP_MASK, %g4
   ! This does %g4 = (%g4 + 1) mod detected_sparc_register_windows
   add     %g4, 0x1, %g4
   and     %g4, %g7, %g4
   ! Create the bitmask and store it in %g6
   mov     0x1, %g6
   sll     %g6, %g4, %g6

   !
   ! Read the WIM to determine the position of the invalid window, and store it in %g5.
   ! Since we are working with traps disabled, we should avoid entering the invalid
   ! window when moving using the RESTORE instruction, or otherwise the processor
   ! will be thrown into error mode.
   mov     %wim, %g5

   !
   ! We need to store the PSR value in a global register because we will
   ! need to use it in order to go back to the trap window once we are done.
   ! However, there are no local registers left available to back globals up.
   !
   ! Lucky us, one of the occupied locals already contains the PSR value
   ! that we need, so we can swap its value with that of a global without
   ! losing any important data.
   !
   ! I will use a swapping technique that does not require any additional
   ! registers for auxiliar storage, just because I like it :P
   xor     %g3, %l0, %l0  ! %l0' = %g3 xor %l0
   xor     %g3, %l0, %g3  ! %g3' = (%g3 xor %l0) xor %g3 = %l0
   xor     %g3, %l0, %l0  ! %l0' = (%g3 xor %l0) xor %l0 = %g3

   !
   ! At this point:
   ! * %g7 = WIM register implemented bits mask = NWINDOWS-1
   ! * %g6 = Mask for the most recently used in-use register window.
   ! * %g5 = Initial WIM register value = invalid window mask
   ! * %g4 = Available for scratch.
   ! * %g3 = Initial PSR value.

dump_frame_loop:

   !
   ! Move one register window up and save its contents to the stack using
   ! STD for performance. That requires %sp to be double word aligned.
   restore

   std     %l0, [%sp]
   std     %l2, [%sp + 8]
   std     %l4, [%sp + 16]
   std     %l6, [%sp + 24]
   std     %i0, [%sp + 32]
   std     %i2, [%sp + 40]
   std     %i4, [%sp + 48]
   std     %i6, [%sp + 56]

   !
   ! Rotate the invalid bit mask one bit to the right in order to check
   ! if the next RESTORE would enter the invalid window and therefore
   ! throw the processor into error mode.
   !
   ! This is probably not the most obvious way to do it (that would
   ! probably be to rotate the mask for the lowest in-use window stored
   ! %g6 one bit to the LEFT) but I do it this way in order to preserve
   ! the value of %g6 for later, when I will need to use that window
   ! mask to reconfigure the WIM register. Remember that I have a very limited
   ! set of registers to work with, so I can't back the value up, and I would
   ! rather not calculate it again.
   !
   srl     %g5, 0x1, %g4
   sll     %g5, %g7, %g5 ! the WIM bit mask is also NWINDOWS - 1
   or      %g4, %g5, %g5
   and     %g5, %g7, %g5 ! erase any extra bits

   !
   ! Check if the next restore will enter the invalid window
   subcc   %g5, %g6, %g0
   bne     dump_frame_loop
   nop

exit_dump_frame_loop:

   !
   ! At this point:
   ! * %g7 = WIM register implemented bits mask = NWINDOWS-1
   ! * %g6 = Mask for the most recently used in-use register window.
   ! * %g5 = Mask for the most recently used in-use register window.
   ! * %g4 = Available for scratch.
   ! * %g3 = PSR value.

   !
   ! Reconfigure the WIM register in order to invalidate the window right above the
   ! trap window.
   mov     %g6, %wim

   !
   ! Move back to the trap window
   mov     %g3, %psr
   ! Since we have overwritten the CWP field, the result of any access to any local register
   ! is undefined during the next three cycles.
   nop
   nop
   nop

   !
   ! SWAP the value of the register back to its original place in %l0
   xor     %g3, %l0, %l0  ! %l0' = %g3 xor %l0
   xor     %g3, %l0, %g3  ! %g3' = (%g3 xor %l0) xor %g3 = %l0
   xor     %g3, %l0, %l0  ! %l0' = (%g3 xor %l0) xor %l0 = %g3

   ! ****************************************************
   !
   ! Store the interrupted thread's context to the thread's stack
   !

   ! Notice that the usage of STD below requires %sp to be double word aligned, but since
   ! that is a requirement of the SPARC architecture, the compiler always complies with that alignment
   ! restriction. That is also the reason why I save 80 bytes for the thread's context, instead
   ! of only 76 bytes (the actual occupied stack space). See appendix D "Software considerations"
   ! in the SPARC V8 Architecture Manual).

   ! Make some room on the stack for the thread context, keeping %sp double word aligned.
   sub     %fp, SPARC_STACK_BASE_CONTEXT_RESERVATION_SIZE, %sp

   ! Save the PSR register
   st      %l0, [%sp]

   ! Save the Global registers %g1 to %g7
   st      %g1, [%sp + 4]
   std     %g2, [%sp + 8]
   std     %l4, [%sp + 16] ! ATTENTION HERE: %g4 and %g5 were relocated to %l4 and %l5
   std     %l6, [%sp + 24] ! ATTENTION HERE: %g6 and %g7 were relocated to %l6 and %l7

   ! Save the In registers %i0 to %i7
   std     %i0, [%sp + 32]
   std     %i2, [%sp + 40]
   std     %i4, [%sp + 48]
   std     %i6, [%sp + 56]

   ! Read the Y register, and save it
   mov     %y, %l5
   st      %l5, [%sp + 64]

   ! Finally save the PC and nPC that indicate the address where the thread was interrupted.
   st      %l1, [%sp + 68]
   st      %l2, [%sp + 72]

   ! ****************************************************
   !
   ! FPU TASK CONTEXT SAVE
   !
   ! If support for FPU instructions is added to the port, this is the place where
   ! the FPU context needs to be saved.
   !
   ! The outline would be:
   ! 1) Make some room in the stack for the FPU registers. Make sure you keep everything
   !    double word aligned.
   ! 2) Store the FPU registers to the stack.
   ! 3) Save the FSR register too.
   !
   ! ****************************************************

   ! ****************************************************
   !
   ! The stack pointer is now the key to all of the interrupted thread's
   ! context information. Store it in a global variable so that schedule()
   ! can work with it if it is called from within the trap service routine.
   !

   sethi   %hi(active_thread_context_stack_pointer), %l4
   st      %sp, [%lo(active_thread_context_stack_pointer) + %l4]

   ! ****************************************************
   !
   ! DEDICATED INTERRUPT STACK
   !
   ! If we wanted to use a dedicated interrupt stack,
   ! this is the place where we should replace the stack
   ! pointer so that it points to it.
   !
   ! ****************************************************

   ! ****************************************************
   !
   ! Re-enable traps
   !

   mov     %l0, %l4
   or      %l4, SPARC_PSR_ET_MASK, %l4 ! Set the ET bit
   mov     %l4, %psr
   ! delay cycles
   nop
   nop
   nop

   ! ****************************************************
   !
   ! Call the IRQ handler caller function, or
   ! the task context replacement function caller function.
   !

   ! The prototype of these functions is
   !
   !   void callerFunction(uint32_t arg);
   !
   ! They require a single integer argument, that depending on the case is the IRQ number
   ! whose interrupt handler must be executed, or the taskContextReplacement service
   ! that must be called. According to the Sparc ABI, this argument mus be stored in %o0.

   ! The value of that argument is stored on the first
   ! 5 bits of %l3. The sixth bit is a flag that indicates whether
   ! this code is being executed to handle an external interrupt (IRQ)
   ! or a software trap (the set/change context system services).

   ! Test whether we must call a interrupt handler or task context
   ! replacement handler function (check bit 6).
   andcc    %l3, 0x20, %g0
   bnz      outermost_set_task_context_replacement_handler_address
   ! There is no need to put something in this delay slot

outermost_set_interrupt_handler_caller_address:

   sethi   %hi(sparcInterruptHandlerCaller), %l4
   jmpl    [%lo(sparcInterruptHandlerCaller) + %l4], %o7
   ! Use the delay slot to store the only argument
   and     %l3, 0x1f, %o0

   ba outermost_jump_to_caller
   nop

outermost_set_task_context_replacement_handler_address:

   sethi   %hi(sparcTaskContextReplacementHandlerCaller), %l4
   jmpl    [%lo(sparcTaskContextReplacementHandlerCaller) + %l4], %o7
   ! Use the delay slot to store the only argument
   and     %l3, 0x1f, %o0

outermost_jump_to_caller:

   ! ****************************************************
   !
   ! Disable traps
   !

   mov     SPARC_SYSCALL_ID_ENABLE_TRAPS, %g1
   ta      SPARC_SYSCALL_SERVICE_SW_TRAP_NUMBER

   ! ****************************************************
   !
   ! Set the interrupt context flag to 0.
   !

   sethi   %hi(system_in_interrupt_context), %l4
   st      %g0, [%lo(system_in_interrupt_context) + %l4]

   ! ****************************************************
   !
   ! Recover the currently active task stack pointer
   !
   ! If there was a task context switch during the execution of the trap service
   ! routine, we will be recovering the state of the recently activated task
   ! instead of the task whose context we saved before calling the trap service
   ! routine.
   !

   sethi   %hi(active_thread_context_stack_pointer), %l4
   ld      [%lo(active_thread_context_stack_pointer) + %l4], %sp

   ! ****************************************************
   !
   ! Recovers the interrupted thread's context from the stack.
   !

   ! ****************************************************
   !
   ! FPU TASK CONTEXT RESTORE
   !
   ! If support for FPU instructions is added to the port, this is the place where
   ! the FPU context needs to be restored
   !
   ! The outline would be:
   ! 1) Restore the FSR register.
   ! 2) Restore the FPU registers.
   ! 3) Release stack space, keeping everygthing double word aligned.
   !
   ! ****************************************************

   ! Load the PSR register
   ld      [%sp], %l0

   ! Restore the values of the Global registers %g1 to %g7
   ld      [%sp + 4], %g1
   ldd     [%sp + 8], %g2
   ldd     [%sp + 16], %g4
   ldd     [%sp + 24], %g6

   ! Restore the values of the In registers %i0 to %i7
   ldd     [%sp + 32], %i0
   ldd     [%sp + 40], %i2
   ldd     [%sp + 48], %i4
   ldd     [%sp + 56], %i6

   ! Restore the value of the Y register
   ld      [%sp + 64], %l5
   mov     %l5, %y

   ! Restore the values of the PC and nPC
   ld      [%sp + 68], %l1
   ld      [%sp + 72], %l2

   ! The thread's stack pointer was recovered along with the
   ! rest of the input registers, no need to derive it from
   ! %fp.

   ! ****************************************************
   !
   ! Return to the interrupted thread
   !

   ba return_from_trap
   nop

   ! ****************************************************
   ! ****************************************************
   ! ****************************************************

nested_trap_handler:

   ! ****************************************************
   !
   ! Makes sure that there's at least one register window available for further traps.
   !

   !
   ! Determine the WIM register bit mask from the number of register windows
   sethi   %hi(detected_sparc_register_windows), %l7
   ld      [%lo(detected_sparc_register_windows) + %l7], %l7
   ! The number of implemented register windows is always a power of 2, therefore the following
   ! sentence determines the implemented windows bit mask.
   sub     %l7, 0x1, %l7

   ! Isolate the CWP field of the PSR register and use it to determine the mask associated
   ! to the trap window
   and     %l0, SPARC_PSR_CWP_MASK, %l4
   mov     0x1, %l6
   sll     %l6, %l4, %l6

   ! Read the WIM register to determine the position of the invalid window
   mov     %wim, %l5

   ! Check if the trap window overlaps the invalid window
   subcc   %l5, %l6, %g0
   bne     no_overflow_yet
   nop

solve_overflow_condition:

   ! There's no room left for another trap in the register window set, so
   ! we are already in a window overflow situation. We need to vacate
   ! the least recently used register window and move the invalid
   ! marker to that window.
   !
   ! The least recently used window is the one inmediately below
   ! the invalid window (modulo NWINDOWS). Rotate the WIM value one
   ! bit to the right in order to get the new value for the WIM register.
   srl     %l5, 0x1, %l4
   sll     %l5, %l7, %l5 ! the WIM bit mask is also NWINDOWS - 1
   or      %l4, %l5, %l5
   and     %l5, %l7, %l5 ! erase any extra bits

   ! We should not update the WIM register yet, otherwise when we
   ! execute the SAVE instruction below, the processor will be thrown
   ! into error mode. This is because the traps are currently disabled
   ! and SAVE would detect that the window set that we are getting into is
   ! marked as invalid in the WIM register.
   !
   ! For similar reasons we must update the WIM register BEFORE executing
   ! the RELEASE instruction that will bring us back to the trap window.
   !
   ! In order to do that, we'll need to carry the updated WIM value with
   ! us in a global register when we change windows, so we must back one up.
   mov     %g5, %l7
   mov     %l5, %g5

   ! Move one window below.
   save

   ! Save the contents of the window to the stack
   std     %l0, [%sp]
   std     %l2, [%sp + 8]
   std     %l4, [%sp + 16]
   std     %l6, [%sp + 24]
   std     %i0, [%sp + 32]
   std     %i2, [%sp + 40]
   std     %i4, [%sp + 48]
   std     %i6, [%sp + 56]

   ! Update the WIM register
   mov     %g5, %wim
   ! Delay cycles
   nop
   nop
   nop

   ! Go back to the trap window
   restore

   ! Restore the value of the global register that we used
   mov     %l7, %g5

no_overflow_yet:

   ! done releasing a window

   ! ****************************************************
   !
   ! Store the interrupted trap service routine's context to the stack
   !

   ! Notice that the usage of STD below requires %sp to be double word aligned, but since
   ! that is a requirement of the SPARC architecture, the compiler always complies with that alignment
   ! restriction. That is also the reason why I save 80 bytes for the thread's context, instead
   ! of only 76 bytes (the actual occupied stack space). See appendix D "Software considerations"
   ! in the SPARC V8 Architecture Manual).

   ! Make some room on the stack for the thread context, keeping %sp double word aligned.
   sub     %fp, SPARC_STACK_BASE_CONTEXT_RESERVATION_SIZE, %sp

   ! Save the PSR register
   st      %l0, [%sp]

   ! Save the Global registers %g1 to %g7
   st      %g1, [%sp + 4]
   std     %g2, [%sp + 8]
   std     %g4, [%sp + 16]
   std     %g6, [%sp + 24]

   ! Save the In registers %i0 to %i7
   std     %i0, [%sp + 32]
   std     %i2, [%sp + 40]
   std     %i4, [%sp + 48]
   std     %i6, [%sp + 56]

   ! Read the Y register, and save it
   mov     %y, %l5
   st      %l5, [%sp + 64]

   ! Finally save the PC and nPC that indicate the address where the trap service routine was interrupted.
   st      %l1, [%sp + 68]
   st      %l2, [%sp + 72]

   !
   ! Notice that there are no provisions for storing the floating point
   ! context here. That is because I assume that under no circunstances a
   ! trap (external or internal) should perform floating point operations.
   !

   ! ****************************************************
   !
   ! Re-enable traps.
   !

   mov     %l0, %l4
   or      %l4, SPARC_PSR_ET_MASK, %l4 ! Set the ET bit
   mov     %l4, %psr
   ! delay cycles
   nop
   nop
   nop

   ! ****************************************************
   !
   ! Call the IRQ handler caller function, or
   ! the task context replacement function caller function.
   !

   ! The prototype of these functions is
   !
   !   void callerFunction(uint32_t arg);
   !
   ! They require a single integer argument, that depending on the case is the IRQ number
   ! whose interrupt handler must be executed, or the taskContextReplacement service
   ! that must be called. According to the Sparc ABI, this argument mus be stored in %o0.

   ! The value of that argument is stored on the first
   ! 5 bits of %l3. The sixth bit is a flag that indicates whether
   ! this code is being executed to handle an external interrupt (IRQ)
   ! or a software trap (the set/change context system services).

   ! Test whether we must call a interrupt handler or task context
   ! replacement handler function (check bit 6).
   andcc    %l3, 0x20, %g0
   bnz      nested_set_task_context_replacement_handler_address
   ! There is no need to put something in this delay slot

nested_set_interrupt_handler_caller_address:

   sethi   %hi(sparcInterruptHandlerCaller), %l4
   jmpl    [%lo(sparcInterruptHandlerCaller) + %l4], %o7
   ! Use the delay slot to store the only argument
   and     %l3, 0x1f, %o0

   ba nested_jump_to_caller
   nop

nested_set_task_context_replacement_handler_address:

   sethi   %hi(sparcTaskContextReplacementHandlerCaller), %l4
   jmpl    [%lo(sparcTaskContextReplacementHandlerCaller) + %l4], %o7
   ! Use the delay slot to store the only argument
   and     %l3, 0x1f, %o0

nested_jump_to_caller:

   ! ****************************************************
   !
   ! Disable traps
   !

   mov     SPARC_SYSCALL_ID_ENABLE_TRAPS, %g1
   ta      SPARC_SYSCALL_SERVICE_SW_TRAP_NUMBER

   ! ****************************************************
   !
   ! Recovers the interrupted trap service routine's context from the stack.
   !

   ! Load the PSR register
   ld      [%sp], %l0

   ! Restore the values of the Global registers %g1 to %g7
   ld      [%sp + 4], %g1
   ldd     [%sp + 8], %g2
   ldd     [%sp + 16], %g4
   ldd     [%sp + 24], %g6

   ! Restore the values of the In registers %i0 to %i7
   ldd     [%sp + 32], %i0
   ldd     [%sp + 40], %i2
   ldd     [%sp + 48], %i4
   ldd     [%sp + 56], %i6

   ! Restore the value of the Y register
   ld      [%sp + 64], %l5
   mov     %l5, %y

   ! Restore the values of the PC and nPC
   ld      [%sp + 68], %l1
   ld      [%sp + 72], %l2

   ! The interrupted trap's stack pointer was recovered along with the
   ! rest of the input registers, no need to derive it from
   ! %fp.

return_from_trap:

   ! ****************************************************
   !
   ! Return from the trap
   !
   ! This universal handler may be used for both interrupting and precise traps.
   ! Interrupting traps must reexecute the instruction where the trap was invoked.
   ! All other trap types are assumed to be precise traps
   !
   ! The sixth bit of the %l3 register is set if this code is handling
   ! a software trap handler request (precise trap).

   andcc   %l3, 0x20, %g0
   bnz     return_from_a_precise_trap
   nop

return_from_an_interrupting_trap:

   !
   ! Reexecute the instruction where the trap was invoked
   jmp     %l1
   rett    %l2

return_from_a_precise_trap:

   !
   ! Go back to the instruction located right after the instruction that trapped.
   jmp     %l2
   rett    %l2 + 0x04
