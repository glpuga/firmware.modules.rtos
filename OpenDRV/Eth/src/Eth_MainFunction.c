/* Copyright 2008, 2009, Mariano Cerdeiro
 *
 * This file is part of OpenSEK.
 *
 * OpenSEK is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *             
 * Linking OpenSEK statically or dynamically with other modules is making a
 * combined work based on OpenSEK. Thus, the terms and conditions of the GNU
 * General Public License cover the whole combination.
 *
 * In addition, as a special exception, the copyright holders of OpenSEK give
 * you permission to combine OpenSEK program with free software programs or
 * libraries that are released under the GNU LGPL and with independent modules
 * that communicate with OpenSEK solely through the OpenSEK defined interface. 
 * You may copy and distribute such a system following the terms of the GNU GPL
 * for OpenSEK and the licenses of the other code concerned, provided that you
 * include the source code of that other code when and as the GNU GPL requires
 * distribution of source code.
 *
 * Note that people who make modified versions of OpenSEK are not obligated to
 * grant this special exception for their modified versions; it is their choice
 * whether to do so. The GNU General Public License gives permission to release
 * a modified version without this exception; this exception also makes it
 * possible to release a modified version which carries forward this exception.
 * 
 * OpenSEK is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with OpenSEK. If not, see <http://www.gnu.org/licenses/>.
 *
 */

/** \brief OpenDRV Ethernet Main Function
 **
 ** This file implements the Ethernet Main Function service
 **
 ** \file Eth_MainFunction.c
 **
 **/

/** \addtogroup OpenDRV
 ** @{ */
/** \addtogroup OpenDRV_Ethernet
 ** @{ */

/*
 * Initials     Name
 * ---------------------------
 * MaCe         Mariano Cerdeiro
 */

/*
 * modification history (new versions first)
 * -----------------------------------------------------------
 * 20081130 v0.1.0 MaCe       - initial version
 */

/*==================[inclusions]=============================================*/
#include "Eth_Internal.h"

/*==================[macros and definitions]=================================*/

/*==================[internal data declaration]==============================*/

/*==================[internal functions declaration]=========================*/

/*==================[internal data definition]===============================*/

/*==================[external data definition]===============================*/

/*==================[internal functions definition]==========================*/

/*==================[external functions definition]==========================*/
void Eth_MainFunction
(
	void
)
{
	uint8f loopi;

#if (OpenDRV_TCPIP == ENABLE)
	/* uip functionality for every TCPIP connection */
	for (loopi = 0; loopi < UIP_CONNS; loopi++)
	{
		uip_periodic(loopi);
		if (uip_len > 0)
		{
			uip_arp_out();
			Eth_Transmit();
		}
	}
#endif /* #if (OpenDRV_TCPIP == ENABLE) */

#if (OpenDRV_UDP == ENABLE)
	/* uip functionality for every UDP connection */
	for (loopi = 0; loopi < UIP_UDP_CONNS; loopi++)
	{
		uip_udp_periodic(loopi);
		if(uip_len > 0)
		{
			uip_arp_out();
			Eth_Transmit();
	}
#endif /* #if (OpenDRV_UDP == ENABLE) */

	/* ?? TODO check this */
	/* while (Eth_Var.Flags.TX_Data > 0)
	{
		Eth_Var.TX_Data--;
		Eth_Receive;
	} */

	/* check if new data was received by the driver */
	while (Eth_Var.RX_Data > 0)
	{
		if(BUF->type == HTONS(UIP_ETHTYPE_IP))
		{
			uip_arp_ipin();
			uip_input();
			if (uip_len > 0)
			{
				uip_arp_out();
				Eth_Transmit();
			}
		}
		else if (BUF->type == HTONS(UIP_ETHTYPE_ARP))
		{
			uip_arp_arpin();
			if (uip_len > 0)
			{
				Eth_Transmit();
			}
		}
		else
		{
			/* nothing to do unknown protocol */	
		}
		
		Eth_Var.RX_Data--;
	}
}

/** @} doxygen end group definition */
/** @} doxygen end group definition */
/*==================[end of file]============================================*/

