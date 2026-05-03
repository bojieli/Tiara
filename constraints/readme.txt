*******************************************************************************
** © Copyright 2021 Xilinx, Inc. All rights reserved.
** This file contains confidential and proprietary information of Xilinx, Inc. and 
** is protected under U.S. and international copyright and other intellectual property laws.
*******************************************************************************
**   ____  ____ 
**  /   /\/   / 
** /___/  \  /   Vendor: Xilinx 
** \   \   \/    
**  \   \        readme.txt Version: 4.0  
**  /   /        Date Last Modified: 05MAY2021
** /___/   /\    Date Created: 02FEB2020
** \   \  /  \   Associated Filename: alveo-u50-xdc.xdc
**  \___\/\___\ 
** 
**  Device: Alveo XCU50
**  Purpose: XDC constraints file
**  Reference: 
**  Revision History: v1.0, A-U50DD
**                    v2.0, A-U55 Added IO Standards, Clocking info and Power constraint.
**                    v3.0, Changed Configuration speed, added pulldown to CATTRIP and Fixed clock description
**                    v4.0, Formatting and spelling corrections in comments (no functional changes)
*******************************************************************************
**
**  Disclaimer: 
**
**		This disclaimer is not a license and does not grant any rights to the materials 
**              distributed herewith. Except as otherwise provided in a valid license issued to you 
**              by Xilinx, and to the maximum extent permitted by applicable law: 
**              (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND WITH ALL FAULTS, 
**              AND XILINX HEREBY DISCLAIMS ALL WARRANTIES AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, 
**              INCLUDING BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-INFRINGEMENT, OR 
**              FITNESS FOR ANY PARTICULAR PURPOSE; and (2) Xilinx shall not be liable (whether in contract 
**              or tort, including negligence, or under any other theory of liability) for any loss or damage 
**              of any kind or nature related to, arising under or in connection with these materials, 
**              including for any direct, or any indirect, special, incidental, or consequential loss 
**              or damage (including loss of data, profits, goodwill, or any type of loss or damage suffered 
**              as a result of any action brought by a third party) even if such damage or loss was 
**              reasonably foreseeable or Xilinx had been advised of the possibility of the same.


**  Critical Applications:
**
**		Xilinx products are not designed or intended to be fail-safe, or for use in any application 
**		requiring fail-safe performance, such as life-support or safety devices or systems, 
**		Class III medical devices, nuclear facilities, applications related to the deployment of airbags,
**		or any other applications that could lead to death, personal injury, or severe property or 
**		environmental damage (individually and collectively, "Critical Applications"). Customer assumes 
**		the sole risk and liability of any use of Xilinx products in Critical Applications, subject only 
**		to applicable laws and regulations governing limitations on product liability.

**  THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS PART OF THIS FILE AT ALL TIMES.

*******************************************************************************


*******************************************************************************

** IMPORTANT NOTES **

1. REVISION HISTORY 

            Readme  
Date        Version      Revision Description
=========================================================================
06AUG2019   1.0          Initial Xilinx release.
17DEC2019   2.0          Revised IOStandards and added clocking and power constraints.
                         Changed pinout from DD to QSFP and added clocking constraints.
09SEP2020   3.0          Changed Configuration speed, added pulldown to CATTRIP and Fixed clock description
05MAY2021   4.0          Formatting and spelling corrections in comments (no functional changes)
=========================================================================



2. DESIGN FILE HIERARCHY

\alveo-u50-xdc.xdc



